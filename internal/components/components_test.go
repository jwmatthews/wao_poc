package components_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/components"
	"github.com/medik8s/workload-availability-operator/internal/operands"
)

func TestRegistryKeysMatchAPI(t *testing.T) {
	want := []string{v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentKeySelfNodeRemediation, v1alpha1.ComponentKeyStorageBasedRemediation,
		v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance}
	all := components.All()
	if len(all) != len(want) {
		t.Fatalf("All() has %d entries, want %d", len(all), len(want))
	}
	for i, d := range all {
		if d.Key != want[i] {
			t.Errorf("All()[%d].Key = %q, want %q", i, d.Key, want[i])
		}
		if got, ok := components.ByKey(d.Key); !ok || got.ShortName != d.ShortName {
			t.Errorf("ByKey(%q) mismatch", d.Key)
		}
	}
	if len(want) != len(v1alpha1.AllComponentKeys) {
		t.Fatalf("registry covers %d of %d API keys", len(want), len(v1alpha1.AllComponentKeys))
	}
}

func TestEveryDefinitionMatchesItsManifests(t *testing.T) {
	for _, d := range components.All() {
		files, err := operands.Load(d.ManifestDir)
		if err != nil || len(files) == 0 {
			t.Fatalf("%s: Load(%q) = %d files, %v", d.Key, d.ManifestDir, len(files), err)
		}
		var all strings.Builder
		for _, b := range files {
			all.Write(b)
		}
		text := all.String()
		for _, img := range d.Images {
			if !strings.Contains(text, img.Original) {
				t.Errorf("%s: original image for %s not found in manifests", d.Key, img.Env)
			}
		}
		for _, dep := range d.Deployments {
			if !strings.Contains(text, "name: "+dep+"\n") {
				t.Errorf("%s: deployment %s not found in manifests", d.Key, dep)
			}
		}
		for _, wh := range d.Webhooks {
			if !strings.Contains(text, "kind: "+wh.Kind+"\n") || !strings.Contains(text, "name: "+wh.Name+"\n") {
				t.Errorf("%s: webhook configuration %s/%s not found", d.Key, wh.Kind, wh.Name)
			}
		}
	}
}

func TestSNRAndSBRDeclareAgentOwners(t *testing.T) {
	snr, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	sbr, _ := components.ByKey(v1alpha1.ComponentKeyStorageBasedRemediation)
	nhc, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	if len(snr.AgentOwners) != 1 || snr.AgentOwners[0].Kind != "SelfNodeRemediationConfig" {
		t.Errorf("SNR agent owners = %+v", snr.AgentOwners)
	}
	if len(sbr.AgentOwners) != 1 || sbr.AgentOwners[0].Kind != "StorageBasedRemediationConfig" {
		t.Errorf("SBR agent owners = %+v", sbr.AgentOwners)
	}
	if len(nhc.AgentOwners) != 0 {
		t.Errorf("NHC has no agents, got %+v", nhc.AgentOwners)
	}
}

func TestEveryComponentDeclaresManagedKinds(t *testing.T) {
	want := map[string]string{
		v1alpha1.ComponentKeyNodeHealthCheck: "NodeHealthCheck", v1alpha1.ComponentKeySelfNodeRemediation: "SelfNodeRemediation",
		v1alpha1.ComponentKeyStorageBasedRemediation: "StorageBasedRemediation", v1alpha1.ComponentKeyFenceAgentsRemediation: "FenceAgentsRemediation",
		v1alpha1.ComponentKeyMachineDeletionRemediation: "MachineDeletionRemediation", v1alpha1.ComponentKeyNodeMaintenance: "NodeMaintenance",
	}
	for _, d := range components.All() {
		if len(d.ManagedKinds) != 1 || d.ManagedKinds[0].Kind != want[d.Key] {
			t.Errorf("%s ManagedKinds = %+v, want %s", d.Key, d.ManagedKinds, want[d.Key])
		}
	}
}

// Original image references are the `upstream` values in release-set.yaml: the runtime overlays
// set them (make operand-manifests) and the renderer swaps them for the pinned RELATED_IMAGE_*.
func TestOriginalImagesMatchReleaseSet(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "release-set.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var rs struct {
		Components map[string]struct {
			Images map[string]struct{ Upstream string } `json:"images"`
		} `json:"components"`
	}
	if err := yaml.Unmarshal(raw, &rs); err != nil {
		t.Fatal(err)
	}
	for _, d := range components.All() {
		comp, ok := rs.Components[d.ShortName]
		if !ok {
			t.Fatalf("%s: no release-set entry %q", d.Key, d.ShortName)
		}
		for _, img := range d.Images {
			if got := comp.Images[img.Env].Upstream; got != img.Original {
				t.Errorf("%s: Original for %s = %q, release-set.yaml upstream = %q", d.Key, img.Env, img.Original, got)
			}
		}
	}
}
