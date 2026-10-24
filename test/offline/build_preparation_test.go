package offline

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Keep the real manager/run/docker-build recipes; stub their costly commands and
// the generator so these tests detect both missing generation and parallel races.
func (tr *tree) buildFixture(withDevTools bool) string {
	tr.t.Helper()
	mockDir := tr.path("build-mocks")
	if err := os.Mkdir(mockDir, 0o755); err != nil {
		tr.t.Fatal(err)
	}
	guard := `test -f .operand-generation-complete || {
 echo 'build started before operand generation' >&2; exit 1;
}
touch .build-started
`
	writeExecutable(tr.t, tr.path("hack/build.sh"), guard)
	writeExecutable(tr.t, filepath.Join(mockDir, "container"), guard)
	realGo := strings.TrimSpace(tr.run("sh", "-c", "command -v go"))
	writeExecutable(tr.t, filepath.Join(mockDir, "go"), fmt.Sprintf(`
if [ "$1" = env ]; then exec %q "$@"; fi
if [ "$1" != run ]; then echo unexpected-go-command >&2; exit 99; fi
%s`, realGo, guard))
	tr.write("build-overrides.mk", []byte(`
.PHONY: operand-manifests generate fmt vet manifests test-no-verify-changes
operand-manifests:
	@test "$(FAIL_GENERATION)" != yes
	@sleep 0.15
	@touch .operand-generation-complete
generate fmt vet manifests test-no-verify-changes go-tidy go-vendor go-verify test-imports envtest:
	@test -f .operand-generation-complete || { echo 'preparation started before operand generation' >&2; exit 1; }
`))
	tr.write("Makefile", append(tr.read("Makefile"), []byte("\ninclude build-overrides.mk\n")...))
	devRecipe := []byte(".PHONY: dev-build\ndev-build:\n\t@container build\n")
	tr.write("fixture-dev.mk", devRecipe)
	toolsDir := tr.path("fixture-tools")
	if withDevTools {
		if err := os.MkdirAll(filepath.Join(toolsDir, "dev"), 0o755); err != nil {
			tr.t.Fatal(err)
		}
		tr.write("fixture-tools/dev/dev.mk", devRecipe)
	} else {
		// Exercise the actual lazy fallback without network access or modifying tools.
		realGit := strings.TrimSpace(tr.run("sh", "-c", "command -v git"))
		writeExecutable(tr.t, filepath.Join(mockDir, "git"), fmt.Sprintf(`
if [ "$1" != clone ]; then exec %q "$@"; fi
for destination in "$@"; do :; done
mkdir -p "$destination/dev"
cp fixture-dev.mk "$destination/dev/dev.mk"
touch .tools-cloned
`, realGit))
	}
	return toolsDir
}

func (tr *tree) buildArgs(target, toolsDir string, failure bool) []string {
	tr.t.Helper()
	args := []string{"PATH=" + tr.path("build-mocks") + ":" + os.Getenv("PATH"),
		"make", "-s", "-j4", target, "TOOLS_DIR=" + toolsDir, "CONTAINER_TOOL=container"}
	if failure {
		args = append(args, "FAIL_GENERATION=yes")
	}
	return args
}

func TestBuildPreparesOperandsBeforeCompilation(t *testing.T) {
	for _, target := range []string{"manager", "run", "docker-build", "dev-build"} {
		for _, failure := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/failure=%t", target, failure), func(t *testing.T) {
				tr := newTree(t)
				toolsDir := tr.buildFixture(true)
				out, err := tr.try("env", tr.buildArgs(target, toolsDir, failure)...)
				if failure {
					if err == nil {
						t.Fatalf("build continued after generator failure: %s", out)
					}
					if _, err := os.Stat(tr.path(".build-started")); !os.IsNotExist(err) {
						t.Fatal("compilation started after failed generation")
					}
				} else {
					if err != nil {
						t.Fatalf("build failed: %v\n%s", err, out)
					}
					if _, err := os.Stat(tr.path(".build-started")); err != nil {
						t.Fatalf("build recipe did not run: %v\n%s", err, out)
					}
				}
			})
		}
	}
}

func TestDevBuildPreparesOperandsAfterLazyToolsDownload(t *testing.T) {
	tr := newTree(t)
	toolsDir := tr.buildFixture(false)
	tr.run("env", tr.buildArgs("help", toolsDir, false)...)
	if _, err := os.Stat(tr.path(".tools-cloned")); !os.IsNotExist(err) {
		t.Fatal("help downloaded tools")
	}
	tr.run("env", tr.buildArgs("dev-build", toolsDir, false)...)
	for _, marker := range []string{".tools-cloned", ".build-started"} {
		if _, err := os.Stat(tr.path(marker)); err != nil {
			t.Fatal("fallback did not complete " + marker)
		}
	}
}
