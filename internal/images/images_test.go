package images

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

func lookupFrom(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestFromEnvReportsEveryMissingVariable(t *testing.T) {
	_, err := FromEnv(lookupFrom(map[string]string{NHCManager: "x"}))
	if err == nil {
		t.Fatal("expected error")
	}
	for _, k := range []string{SNRManager, SBRManager, SBRAgent, FARManager, MDRManager, NMOManager} {
		if !strings.Contains(err.Error(), k) {
			t.Errorf("error %q does not name %s", err, k)
		}
	}
	if strings.Contains(err.Error(), NHCManager) {
		t.Errorf("error should not name the present variable: %q", err)
	}
}

func TestFromEnvRejectsBlankValues(t *testing.T) {
	m := map[string]string{}
	for _, k := range Required {
		m[k] = "img"
	}
	m[SBRAgent] = "  "
	if _, err := FromEnv(lookupFrom(m)); err == nil || !strings.Contains(err.Error(), SBRAgent) {
		t.Fatalf("expected error naming %s, got %v", SBRAgent, err)
	}
}

func TestFromEnvReturnsAllValuesSorted(t *testing.T) {
	m := map[string]string{}
	for i, k := range Required {
		m[k] = "img" + string(rune('a'+i))
	}
	s, err := FromEnv(lookupFrom(m))
	if err != nil {
		t.Fatal(err)
	}
	if s.Get(SNRManager) != m[SNRManager] {
		t.Fatalf("Get mismatch")
	}
	keys := s.Sorted()
	if len(keys) != len(Required) || keys[0] != FARManager {
		t.Fatalf("Sorted() = %v", keys)
	}
}

func TestOperandsYAMLDeclaresExactlyRequiredImages(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "operands.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Operands map[string]struct {
			Images map[string]map[string]any `json:"images"`
		} `json:"operands"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	var got []string
	for key, op := range doc.Operands {
		for env, fields := range op.Images {
			got = append(got, env)
			if _, ok := fields["kustomizeName"]; ok {
				t.Errorf("%s/%s: kustomizeName is no longer used; the runtime overlays are static", key, env)
			}
		}
	}
	want := slices.Clone(Required)
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("operands.yaml images = %v, want %v", got, want)
	}
}
