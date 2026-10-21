package offline

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const latestTag = "latest"

const fixtureDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

func migratePullRefs(rs releaseSet) {
	for _, comp := range rs.Components {
		for _, raw := range comp["images"].(map[string]any) {
			img := raw.(map[string]any)
			tagged := img["tagged"].(string)
			if comp["tag"] == latestTag {
				img["pullRef"] = tagged
			} else {
				img["pullRef"] = tagged[:strings.LastIndex(tagged, ":")] + "@" + fixtureDigest
			}
			delete(img, "pinned")
		}
	}
}

func configurePullRefCase(rs releaseSet, name string) bool {
	img := rs.Components["nhc"]["images"].(map[string]any)["RELATED_IMAGE_NHC_MANAGER"].(map[string]any)
	release := func(comp map[string]any) {
		comp["tag"] = "v9.8.0"
		for _, raw := range comp["images"].(map[string]any) {
			m := raw.(map[string]any)
			tagged := m["tagged"].(string)
			repo := tagged[:strings.LastIndex(tagged, ":")]
			m["tagged"] = repo + ":v9.8.0"
			m["pullRef"] = repo + "@" + fixtureDigest
		}
	}
	valid := false
	switch name {
	case latestTag:
		valid = true
	case "releases":
		for _, comp := range rs.Components {
			release(comp)
		}
		valid = true
	case "mixed":
		release(rs.Components["nhc"])
		valid = true
	case "missing":
		delete(img, "pullRef")
	case "empty":
		img["pullRef"] = ""
	case "latest-digest":
		img["pullRef"] = "quay.io/medik8s/node-healthcheck-operator@" + fixtureDigest
	case "release-tag":
		release(rs.Components["nhc"])
		img["pullRef"] = img["tagged"]
	case "bad-digest":
		release(rs.Components["nhc"])
		img["pullRef"] = "quay.io/medik8s/node-healthcheck-operator@sha256:bad"
	case "wrong-repository":
		release(rs.Components["nhc"])
		img["pullRef"] = "example.test/wrong@" + fixtureDigest
	case "wrong-tag":
		img["tagged"] = "quay.io/medik8s/node-healthcheck-operator:other"
	case "uri":
		img["tagged"] = "https://quay.io/medik8s/node-healthcheck-operator:latest"
		img["pullRef"] = img["tagged"]
	case "extra-tag":
		img["tagged"] = "quay.io/medik8s/node-healthcheck-operator:v1:latest"
		img["pullRef"] = img["tagged"]
	case "numeric-extra-tag":
		img["tagged"] = "node-healthcheck-operator:123:latest"
		img["pullRef"] = img["tagged"]
	case "registry-port":
		img["tagged"] = "localhost:5000/medik8s/node-healthcheck-operator:latest"
		img["pullRef"] = img["tagged"]
		valid = true
	case "short-name":
		img["tagged"] = "node_healthcheck:latest"
		img["pullRef"] = img["tagged"]
		valid = true
	case "duplicate":
		rs.Components["snr"]["images"].(map[string]any)["RELATED_IMAGE_NHC_MANAGER"] = img
	case "legacy":
		img["pinned"] = "obsolete"
	}
	return valid
}

func TestPullRefValidation(t *testing.T) {
	for _, name := range []string{
		latestTag, "releases", "mixed", "missing", "empty", "latest-digest", "release-tag", "bad-digest",
		"wrong-repository", "wrong-tag", "uri", "extra-tag", "numeric-extra-tag",
		"registry-port", "short-name", "duplicate", "legacy",
	} {
		t.Run(name, func(t *testing.T) {
			tr := newTree(t)
			rs := tr.loadReleaseSet()
			migratePullRefs(rs)
			valid := configurePullRefCase(rs, name)
			tr.saveReleaseSet(rs)
			out, err := tr.try("bash", "hack/operand-image-refs.sh")
			if valid {
				if err != nil {
					t.Fatalf("valid references rejected: %v\n%s", err, out)
				}
				if len(strings.Split(strings.TrimSpace(out), "\n")) != 8 {
					t.Fatalf("expected eight references, got %q", out)
				}
				for _, comp := range rs.Components {
					for env, raw := range comp["images"].(map[string]any) {
						want := env + "\t" + raw.(map[string]any)["pullRef"].(string)
						if !strings.Contains(out, want+"\n") {
							t.Errorf("missing %q in %q", want, out)
						}
					}
				}
			} else {
				if err == nil {
					t.Fatalf("invalid references accepted: %s", out)
				}
				if !strings.Contains(out, "RELATED_IMAGE_NHC_MANAGER") {
					t.Fatalf("diagnostic lacks offending image: %s", out)
				}
				before := tr.read("config/manager/manager.yaml")
				if out, err := tr.try("make", "-s", "operand-manifests"); err == nil {
					t.Fatalf("generation accepted invalid input: %s", out)
				}
				if string(before) != string(tr.read("config/manager/manager.yaml")) {
					t.Fatal("invalid input changed manager references")
				}
			}
		})
	}
}

func TestPullRefGenerationTransitions(t *testing.T) {
	tr := newTree(t)
	rs := tr.loadReleaseSet()
	migratePullRefs(rs)
	tr.saveReleaseSet(rs)
	tr.run("make", "-s", "operand-manifests")
	for _, tag := range []string{"v9.8.0", latestTag} {
		rs = tr.loadReleaseSet()
		comp := rs.Components["nhc"]
		comp["tag"] = tag
		for _, raw := range comp["images"].(map[string]any) {
			img := raw.(map[string]any)
			tagged := img["tagged"].(string)
			repo := tagged[:strings.LastIndex(tagged, ":")]
			img["tagged"] = repo + ":" + tag
			img["pullRef"] = img["tagged"]
			if tag != latestTag {
				img["pullRef"] = repo + "@" + fixtureDigest
			}
		}
		tr.saveReleaseSet(rs)
		tr.run("make", "-s", "operand-manifests")
		for env, raw := range comp["images"].(map[string]any) {
			query := fmt.Sprintf(`.spec.template.spec.containers[0].env[] | select(.name == "%s") | .value`, env)
			got := strings.TrimSpace(tr.run("bin/yq", query, "config/manager/manager.yaml"))
			if want := raw.(map[string]any)["pullRef"]; got != want {
				t.Fatalf("%s: got %q, want %q", env, got, want)
			}
		}
		tr.run("go", "test", "./internal/components", "./internal/operands", "-count=1")
	}
}

func writeExecutable(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/usr/bin/env bash\nset -euo pipefail\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestResolvePullRef(t *testing.T) {
	cases := []struct {
		name, selector, current, override, want string
		makeDefault                             bool
	}{
		{name: "make-default", want: latestTag, makeDefault: true},
		{name: "script-default", want: "v9.8.0"},
		{name: latestTag, selector: latestTag, want: latestTag},
		{name: "release", selector: "release", want: "v9.8.0"},
		{name: "version", selector: "v1.2.3", want: "v1.2.3"},
		{name: "keep-latest", selector: "pinned", current: latestTag, want: latestTag},
		{name: "keep-release", selector: "pinned", current: "v1.2.3", want: "v1.2.3"},
		{name: "override", selector: latestTag, override: "v1.2.3", want: "v1.2.3"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tr := newTree(t)
			rs := tr.loadReleaseSet()
			for name := range rs.Components {
				if name != "nhc" {
					delete(rs.Components, name)
				}
			}
			for _, raw := range rs.Components["nhc"]["images"].(map[string]any) {
				raw.(map[string]any)["pinned"] = "quay.io/old@" + fixtureDigest
			}
			if tc.current != "" {
				rs.Components["nhc"]["tag"] = tc.current
			}
			tr.saveReleaseSet(rs)
			mockDir := tr.path("mocks")
			if err := os.Mkdir(mockDir, 0o755); err != nil {
				t.Fatal(err)
			}
			writeExecutable(t, filepath.Join(mockDir, "skopeo"), `echo "$*" >> digest.log; printf '%s' '{}'`)
			writeExecutable(t, filepath.Join(mockDir, "curl"), `printf '%s' '{"tag_name":"v9.8.0"}'`)
			writeExecutable(t, tr.path("hack/image-commit.sh"), `echo "$1" >> commits.log; printf '%040d\n' 1`)
			args := []string{"PATH=" + mockDir + ":" + os.Getenv("PATH"), "NHC_TAG=" + tc.override}
			if tc.makeDefault {
				args = append(args, "make", "-s", "update-release-set")
			} else {
				args = append(args, "OPERAND_TAG="+tc.selector, "bash", "hack/update-release-set.sh")
			}
			tr.run("env", args...)
			comp := tr.loadReleaseSet().Components["nhc"]
			if comp["tag"] != tc.want {
				t.Fatalf("tag = %v, want %s", comp["tag"], tc.want)
			}
			for _, raw := range comp["images"].(map[string]any) {
				img := raw.(map[string]any)
				tagged := img["tagged"].(string)
				want := tagged
				if tc.want != latestTag {
					want = tagged[:strings.LastIndex(tagged, ":")] + fmt.Sprintf("@sha256:%x", sha256.Sum256([]byte("{}")))
				}
				if img["pullRef"] != want {
					t.Errorf("pullRef = %v, want %s", img["pullRef"], want)
				}
				if _, ok := img["pinned"]; ok {
					t.Error("legacy pinned field remains")
				}
				if !strings.Contains(string(tr.read("commits.log")), want+"\n") {
					t.Errorf("commit was not extracted through %s", want)
				}
			}
			if tc.want == latestTag {
				if _, err := os.Stat(tr.path("digest.log")); !os.IsNotExist(err) {
					t.Fatal("latest performed digest lookup")
				}
			}
		})
	}
}

func TestResolvePullRefRejectsCommitFailures(t *testing.T) {
	for _, mode := range []string{"pull-error", "missing", "conflict"} {
		t.Run(mode, func(t *testing.T) {
			tr := newTree(t)
			rs := tr.loadReleaseSet()
			for name := range rs.Components {
				if name != "nhc" {
					delete(rs.Components, name)
				}
			}
			tr.saveReleaseSet(rs)
			script := "exit 1\n"
			if mode == "missing" {
				script = "exit 2\n"
			}
			if mode == "conflict" {
				script = `if [[ "$1" == *node-healthcheck-operator* ]]; then printf '%040d\n' 1; else printf '%040d\n' 2; fi`
			}
			writeExecutable(t, tr.path("hack/image-commit.sh"), script)
			mockDir := tr.path("mocks")
			if err := os.Mkdir(mockDir, 0o755); err != nil {
				t.Fatal(err)
			}
			writeExecutable(t, filepath.Join(mockDir, "skopeo"), "printf '%s' '{}'\n")
			writeExecutable(t, filepath.Join(mockDir, "curl"), "exit 99\n")
			out, err := tr.try("env", "PATH="+mockDir+":"+os.Getenv("PATH"),
				"OPERAND_TAG=latest", "NHC_TAG=", "bash", "hack/update-release-set.sh")
			if err == nil || strings.Contains(out, "updated release-set.yaml") {
				t.Fatalf("resolver accepted %s: %s", mode, out)
			}
		})
	}
}
