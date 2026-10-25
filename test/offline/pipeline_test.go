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
// fresh git checkout so the tests can mutate operands.yaml and regenerate.
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
	for _, file := range []string{"Makefile", "operands.yaml", "go.mod", "go.sum"} {
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
		case "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "GIT_DIR", "GIT_WORK_TREE":
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

// operandInputs contains the developer selections used by the offline pipeline.
type operandInputs struct {
	Operands map[string]map[string]any `json:"operands"`
}

func (tr *tree) loadOperands() operandInputs {
	tr.t.Helper()
	var inputs operandInputs
	if err := yaml.Unmarshal(tr.read("operands.yaml"), &inputs); err != nil {
		tr.t.Fatal(err)
	}
	return inputs
}

func (tr *tree) saveOperands(inputs operandInputs) {
	tr.t.Helper()
	data, err := json.Marshal(inputs)
	if err != nil {
		tr.t.Fatal(err)
	}
	tr.write("operands.yaml", data)
}

// Give every image an independent tag without changing any component definition.
func (tr *tree) changeTags() {
	tr.t.Helper()
	inputs := tr.loadOperands()
	i := 0
	for _, key := range slices.Sorted(maps.Keys(inputs.Operands)) {
		images := inputs.Operands[key]["images"].(map[string]any)
		for _, env := range slices.Sorted(maps.Keys(images)) {
			images[env].(map[string]any)["tag"] = fmt.Sprintf("v9.8.%d-test", i)
			i++
		}
	}
	tr.saveOperands(inputs)
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

func TestGeneratorRejectsMissingTagWithoutOverwriting(t *testing.T) {
	tr := newTree(t)
	tr.run("make", "-s", "operand-manifests")
	before := tr.read(bindings)
	rs := tr.loadOperands()
	images := rs.Operands["nhc"]["images"].(map[string]any)
	delete(images["RELATED_IMAGE_NHC_MANAGER"].(map[string]any), "tag")
	tr.saveOperands(rs)
	out, err := tr.try("bash", "hack/generate-image-bindings.sh")
	if err == nil {
		t.Fatal("generator accepted a missing tag")
	}
	if !strings.Contains(out, "nonempty tag") {
		t.Errorf("unexpected generator output:\n%s", out)
	}
	if string(tr.read(bindings)) != string(before) {
		t.Error("generator overwrote bindings on failure")
	}
}

func TestGeneratorRejectsDuplicateEnvironmentNames(t *testing.T) {
	tr := newTree(t)
	rs := tr.loadOperands()
	snr := rs.Operands["snr"]["images"].(map[string]any)
	maps.Copy(snr, rs.Operands["nhc"]["images"].(map[string]any))
	tr.saveOperands(rs)
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

// NHC enables metrics mTLS only if its ServiceAccount can read the client CA in
// kube-system/extension-apiserver-authentication. The copied Role grants that, but its
// RoleBinding names the unprefixed ServiceAccount, so WAO must rebind it or the CSV drops it.
func TestVerificationRejectsNHCWithoutClientCARead(t *testing.T) {
	tr := newTree(t)
	role := "config/operands/nhc/config/optional/kube-system-rbac/kube_system_role.yaml"
	data := strings.Replace(string(tr.read(role)), "extension-apiserver-authentication", "some-other-configmap", 1)
	tr.write(role, []byte(data))
	out, err := tr.try("make", "-s", "verify-operand-manifests")
	if err == nil {
		t.Fatalf("verification passed although NHC cannot read the client CA\n%s", out)
	}
	if !strings.Contains(out, "extension-apiserver-authentication") {
		t.Fatalf("expected a client CA check failure, got:\n%s", out)
	}
}
