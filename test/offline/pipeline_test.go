package offline

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

const bindings = "internal/components/zz_generated.images.go"

var definitions = []string{"nhc.go", "snr.go", "sbr.go", "far.go", "mdr.go", "nmo.go"}

type tree struct {
	t    *testing.T
	root string
}

// newTree copies the parts of the repository the operand pipeline reads into a
// fresh git checkout so the tests can mutate release-set.yaml and regenerate.
func newTree(t *testing.T) *tree {
	t.Helper()
	src, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for _, dir := range []string{"api", "config", "internal", "bundle", "hack"} {
		if err := os.CopyFS(filepath.Join(root, dir), os.DirFS(filepath.Join(src, dir))); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{"Makefile", "release-set.yaml", "go.mod", "go.sum"} {
		data, err := os.ReadFile(filepath.Join(src, file))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, file), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, dir := range []string{"bin", "vendor"} {
		if info, err := os.Stat(filepath.Join(src, dir)); err == nil && info.IsDir() {
			if err := os.Symlink(filepath.Join(src, dir), filepath.Join(root, dir)); err != nil {
				t.Fatal(err)
			}
		}
	}
	tr := &tree{t: t, root: root}
	tr.run("git", "init", "-q")
	return tr
}

// try runs a command in the tree and returns its combined output and error.
// Dependencies must already be vendored or cached; these tests stay offline.
func (tr *tree) try(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = tr.root
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		switch key {
		case "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "RELEASE_SET", "GIT_DIR", "GIT_WORK_TREE":
			continue
		}
		cmd.Env = append(cmd.Env, kv)
	}
	cmd.Env = append(cmd.Env, "GOPROXY=off", "GOSUMDB=off", "GOTOOLCHAIN=local")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (tr *tree) run(name string, args ...string) string {
	tr.t.Helper()
	out, err := tr.try(name, args...)
	if err != nil {
		tr.t.Fatalf("%s %s: %v\n%s", name, strings.Join(args, " "), err, out)
	}
	return out
}

func (tr *tree) path(rel string) string { return filepath.Join(tr.root, rel) }

func (tr *tree) read(rel string) []byte {
	tr.t.Helper()
	data, err := os.ReadFile(tr.path(rel))
	if err != nil {
		tr.t.Fatal(err)
	}
	return data
}

func (tr *tree) write(rel string, data []byte) {
	tr.t.Helper()
	if err := os.WriteFile(tr.path(rel), data, 0o644); err != nil {
		tr.t.Fatal(err)
	}
}

// releaseSet is the subset of release-set.yaml the tests mutate. Other top-level
// keys are dropped on rewrite; the generator and verifier only read components.
type releaseSet struct {
	Components map[string]map[string]any `json:"components"`
}

func (tr *tree) loadReleaseSet() releaseSet {
	tr.t.Helper()
	var rs releaseSet
	if err := yaml.Unmarshal(tr.read("release-set.yaml"), &rs); err != nil {
		tr.t.Fatal(err)
	}
	return rs
}

// saveReleaseSet writes the release set as JSON, which yq and the YAML parsers accept.
func (tr *tree) saveReleaseSet(rs releaseSet) {
	tr.t.Helper()
	data, err := json.Marshal(rs)
	if err != nil {
		tr.t.Fatal(err)
	}
	tr.write("release-set.yaml", data)
}

// changeTags gives every component a new tag, retags its images and rewrites
// the UPSTREAM.yaml stamps so verification sees a consistent bump.
func (tr *tree) changeTags() {
	tr.t.Helper()
	rs := tr.loadReleaseSet()
	for i, name := range slices.Sorted(maps.Keys(rs.Components)) {
		comp := rs.Components[name]
		tag := fmt.Sprintf("v9.8.%d-test", i)
		comp["tag"] = tag
		for _, img := range comp["images"].(map[string]any) {
			m := img.(map[string]any)
			tagged := m["tagged"].(string)
			m["tagged"] = tagged[:strings.LastIndex(tagged, ":")] + ":" + tag
		}
		stamp, err := json.Marshal(map[string]any{"repo": comp["repo"], "tag": tag, "commit": comp["commit"]})
		if err != nil {
			tr.t.Fatal(err)
		}
		tr.write(filepath.Join("config/operands", name, "UPSTREAM.yaml"), stamp)
	}
	tr.saveReleaseSet(rs)
}

func TestTagChangesRegenerateBindingsWithoutEditingDefinitions(t *testing.T) {
	tr := newTree(t)
	before := map[string][]byte{}
	for _, name := range definitions {
		before[name] = tr.read(filepath.Join("internal/components", name))
	}
	tr.changeTags()
	tr.run("make", "-s", "operand-manifests")
	tr.run("go", "test", "./internal/components", "./internal/operands", "-count=1")
	for name, want := range before {
		if got := tr.read(filepath.Join("internal/components", name)); string(got) != string(want) {
			t.Errorf("%s changed", name)
		}
	}
}

func TestVerificationAcceptsUnstagedGeneratedUpdates(t *testing.T) {
	tr := newTree(t)
	tr.run("git", "add", "config", "internal")
	tr.changeTags()
	tr.run("make", "-s", "operand-manifests")
	tr.run("make", "-s", "verify-operand-manifests")
}

func TestVerificationRejectsStaleBindings(t *testing.T) {
	tr := newTree(t)
	tr.run("make", "-s", "operand-manifests")
	re := regexp.MustCompile(`("RELATED_IMAGE_NHC_MANAGER":\s*")[^"]+`)
	content := tr.read(bindings)
	if n := len(re.FindAll(content, -1)); n != 1 {
		t.Fatalf("found %d NHC manager bindings in %s, want 1", n, bindings)
	}
	tr.write(bindings, re.ReplaceAll(content, []byte(`${1}example.test/nhc:stale`)))
	out, err := tr.try("make", "-s", "verify-operand-manifests")
	if err == nil {
		t.Fatalf("verification accepted a stale binding:\n%s", out)
	}
	if !strings.Contains(out, "generated") {
		t.Errorf("expected a generated-files message, got:\n%s", out)
	}
}

func TestGeneratorRejectsMissingTaggedReferenceWithoutOverwriting(t *testing.T) {
	tr := newTree(t)
	tr.run("make", "-s", "operand-manifests")
	before := tr.read(bindings)
	rs := tr.loadReleaseSet()
	images := rs.Components["nhc"]["images"].(map[string]any)
	delete(images["RELATED_IMAGE_NHC_MANAGER"].(map[string]any), "tagged")
	tr.saveReleaseSet(rs)
	out, err := tr.try("bash", "hack/generate-image-bindings.sh")
	if err == nil {
		t.Fatal("generator accepted a missing tagged reference")
	}
	if !strings.Contains(out, "nonempty tagged reference") {
		t.Errorf("unexpected generator output:\n%s", out)
	}
	if string(tr.read(bindings)) != string(before) {
		t.Error("generator overwrote bindings on failure")
	}
}

func TestGeneratorRejectsDuplicateEnvironmentNames(t *testing.T) {
	tr := newTree(t)
	rs := tr.loadReleaseSet()
	snr := rs.Components["snr"]["images"].(map[string]any)
	maps.Copy(snr, rs.Components["nhc"]["images"].(map[string]any))
	tr.saveReleaseSet(rs)
	before := tr.read(bindings)
	out, err := tr.try("bash", "hack/generate-image-bindings.sh")
	if err == nil {
		t.Fatal("generator accepted duplicate environment names")
	}
	if !strings.Contains(out, "must be unique") {
		t.Errorf("unexpected generator output:\n%s", out)
	}
	if string(tr.read(bindings)) != string(before) {
		t.Error("generator overwrote bindings on failure")
	}
}

func TestBumpRunsStepsInOrderUnderParallelMakeAndStopsOnFailure(t *testing.T) {
	tr := newTree(t)
	log := tr.path("steps.log")
	steps := []string{"update-release-set", "update-operand-manifests", "verify-operand-manifests"}
	for i, step := range steps {
		previous := ""
		if i > 0 {
			previous = steps[i-1]
		}
		script := fmt.Sprintf(`#!/usr/bin/env bash
echo %q >> %q
if [ -n %q ] && [ ! -e .completed-%s ]; then echo "previous step has not completed: %s" >&2; exit 1; fi
if [ "$FAIL_STEP" = %q ]; then exit 1; fi
sleep 0.15
touch .completed-%s
`, step, log, previous, previous, previous, step, step)
		if err := os.WriteFile(tr.path("hack/"+step+".sh"), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	tr.run("make", "-j4", "bump-operands")
	if got := strings.Fields(string(tr.read("steps.log"))); !slices.Equal(got, steps) {
		t.Fatalf("steps ran as %v, want %v", got, steps)
	}
	if err := os.Remove(log); err != nil {
		t.Fatal(err)
	}
	for _, step := range steps {
		if err := os.Remove(tr.path(".completed-" + step)); err != nil {
			t.Fatal(err)
		}
	}
	out, err := tr.try("make", "-j4", "bump-operands", "FAIL_STEP=update-operand-manifests")
	if err == nil {
		t.Fatalf("bump-operands succeeded past a failing step:\n%s", out)
	}
	if got := strings.Fields(string(tr.read("steps.log"))); !slices.Equal(got, steps[:2]) {
		t.Errorf("steps ran as %v after failure, want %v", got, steps[:2])
	}
}
