package offline

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/yaml"

	v1alpha1 "github.com/medik8s/workload-availability-operator/api/v1alpha1"
)

const waoCRDFile = "workloadavailability.medik8s.io_workloadavailabilityconfigs.yaml"
const waoCSVFile = "workload-availability-operator.clusterserviceversion.yaml"

var componentDisplayNames = map[string]string{
	"nodeHealthCheck":            "Node Health Check",
	"selfNodeRemediation":        "Self Node Remediation",
	"storageBasedRemediation":    "Storage Based Remediation",
	"fenceAgentsRemediation":     "Fence Agents Remediation",
	"machineDeletionRemediation": "Machine Deletion Remediation",
	"nodeMaintenance":            "Node Maintenance",
}

// These checks protect the console form contract in both generated copies.
func TestResourceConfigurationSchemaAndConsole(t *testing.T) {
	for _, artifact := range []struct {
		name string
		crd  string
		csv  string
	}{
		{"base", "config/crd/bases/" + waoCRDFile, "config/manifests/bases/" + waoCSVFile},
		{"bundle", "bundle/manifests/" + waoCRDFile, "bundle/manifests/" + waoCSVFile},
	} {
		t.Run(artifact.name, func(t *testing.T) {
			schema := readResourceCRDSchema(t, artifact.crd)
			for _, key := range v1alpha1.AllComponentKeys {
				t.Run(key, func(t *testing.T) {
					assertComponentResourceSchema(t, schema, key)
				})
			}

			csv := readResourceYAML(t, artifact.csv)
			owned, _, err := unstructured.NestedSlice(csv, "spec", "customresourcedefinitions", "owned")
			if err != nil {
				t.Fatal(err)
			}
			var descriptors []any
			for _, entry := range owned {
				definition := entry.(map[string]any)
				if definition["name"] == "workloadavailabilityconfigs.workloadavailability.medik8s.io" {
					descriptors, _, err = unstructured.NestedSlice(definition, "specDescriptors")
					if err != nil {
						t.Fatal(err)
					}
				}
			}
			byPath := map[string]map[string]any{}
			positions := map[string]int{}
			for index, entry := range descriptors {
				descriptor := entry.(map[string]any)
				path, _ := descriptor["path"].(string)
				if _, duplicate := byPath[path]; duplicate {
					t.Errorf("duplicate descriptor path %q", path)
				}
				byPath[path] = descriptor
				positions[path] = index
				resourceSchemaAt(t, schema, "spec."+path)
				if strings.HasSuffix(path, ".state") {
					t.Errorf("legacy state descriptor %q", path)
				}
				xDescriptors, _, err := unstructured.NestedStringSlice(descriptor, "x-descriptors")
				if err != nil {
					t.Fatal(err)
				}
				for _, value := range xDescriptors {
					if strings.Contains(value, ":select:Enabled") ||
						strings.Contains(value, ":select:Disabled") || strings.Contains(value, ":fieldGroup") {
						t.Errorf("unsupported descriptor %q at %s", value, path)
					}
				}
			}
			for _, key := range v1alpha1.AllComponentKeys {
				prefix := "components." + key
				if positions[prefix+".manager.resources"] != positions[prefix+".enabled"]+2 {
					t.Errorf("%s enable and resource controls are not adjacent to its Manager descriptor", key)
				}
				for _, control := range []struct{ suffix, name, kind string }{
					{"enabled", "Enabled", "booleanSwitch"},
					{"manager.resources", "Manager Resources", "resourceRequirements"},
				} {
					path := "components." + key + "." + control.suffix
					descriptor := byPath[path]
					if descriptor == nil {
						t.Errorf("missing %s descriptor", path)
						continue
					}
					wantName := componentDisplayNames[key] + " " + control.name
					if descriptor["displayName"] != wantName {
						t.Errorf("%s display name = %v, want %s", path, descriptor["displayName"], wantName)
					}
					xDescriptors, _, err := unstructured.NestedStringSlice(descriptor, "x-descriptors")
					if err != nil {
						t.Fatal(err)
					}
					want := "urn:alm:descriptor:com.tectonic.ui:" + control.kind
					if !slices.Contains(xDescriptors, want) {
						t.Errorf("%s descriptors = %v, want %s", path, xDescriptors, want)
					}
				}
			}
			annotation, _, err := unstructured.NestedString(csv, "metadata", "annotations", "alm-examples")
			if err != nil {
				t.Fatal(err)
			}
			var examples []map[string]any
			if err := json.Unmarshal([]byte(annotation), &examples); err != nil {
				t.Fatal(err)
			}
			if len(examples) != 1 {
				t.Fatalf("expected one default example, got %d", len(examples))
			}
			assertResourceDefaultExample(t, examples[0])
		})
	}
}

// Generated quantity patterns must reject exponents that ParseQuantity cannot read.
func TestResourceConfigurationQuantityPatterns(t *testing.T) {
	cases := []struct {
		quantity string
		valid    bool
	}{
		{"1e1.5", false},
		{"1e.5", false},
		{"1e9223372036854775808", false},
		{"1e-9223372036854775809", false},
		{"100m", true},
		{"128Mi", true},
		{"0", true},
		{"-1", true},
		{"1e-3", true},
		{"1E", true},
		{"1E+2", true},
		{"1e9223372036854775807", true},
		{"1e-9223372036854775808", true},
		{"1e000000000000000000003", true},
	}
	for _, artifact := range []struct{ name, crd string }{
		{"base", "config/crd/bases/" + waoCRDFile},
		{"bundle", "bundle/manifests/" + waoCRDFile},
	} {
		t.Run(artifact.name, func(t *testing.T) {
			schema := readResourceCRDSchema(t, artifact.crd)
			for _, key := range v1alpha1.AllComponentKeys {
				for _, field := range []string{"requests", "limits"} {
					t.Run(key+"/"+field, func(t *testing.T) {
						path := "spec.components." + key + ".manager.resources." + field
						resourceMap := resourceSchemaAt(t, schema, path)
						pattern, found, err := unstructured.NestedString(resourceMap, "additionalProperties", "pattern")
						if err != nil || !found {
							t.Fatalf("%s quantity pattern is missing: %v", path, err)
						}
						quantityPattern, err := regexp.Compile(pattern)
						if err != nil {
							t.Fatalf("%s quantity pattern does not compile: %v", path, err)
						}
						for _, tc := range cases {
							if got := quantityPattern.MatchString(tc.quantity); got != tc.valid {
								t.Errorf("%s pattern accepts %q = %t, want %t", path, tc.quantity, got, tc.valid)
							}
						}
					})
				}
			}
		})
	}
}

func TestResourceConfigurationDefaultSample(t *testing.T) {
	sample := readResourceYAML(t, "config/samples/workloadavailability_v1alpha1_workloadavailabilityconfig.yaml")
	assertResourceDefaultExample(t, sample)
}

func TestResourceConfigurationEnableScript(t *testing.T) {
	dir := t.TempDir()
	capture := filepath.Join(dir, "arguments")
	// Replace only the cluster command. Execute the real script and inspect its patch.
	writeExecutable(t, filepath.Join(dir, "oc"), `printf '%s\n' "$@" > "$WAO_TEST_OC_CAPTURE"`)
	script, err := filepath.Abs(filepath.Join("..", "..", "hack", "enable_all.sh"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", script)
	cmd.Env = append(os.Environ(),
		"PATH="+dir+":"+os.Getenv("PATH"),
		"KUBECONFIG="+filepath.Join(dir, "test.kubeconfig"),
		"WAO_TEST_OC_CAPTURE="+capture,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("enable script failed: %v\n%s", err, out)
	}
	data, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	wantPrefix := []string{
		"--kubeconfig", filepath.Join(dir, "test.kubeconfig"),
		"patch", "workloadavailabilityconfig", "cluster", "--type", "merge", "-p",
	}
	if len(args) != len(wantPrefix)+1 || !slices.Equal(args[:min(len(args), len(wantPrefix))], wantPrefix) {
		t.Fatalf("unexpected oc arguments: %q", args)
	}
	var patch map[string]any
	if err := json.Unmarshal([]byte(args[len(wantPrefix)]), &patch); err != nil {
		t.Fatal(err)
	}
	components, found, err := unstructured.NestedMap(patch, "spec", "components")
	if err != nil || !found {
		t.Fatalf("missing components patch: %v", err)
	}
	if len(components) != len(v1alpha1.AllComponentKeys) {
		t.Errorf("patch has %d components, want %d", len(components), len(v1alpha1.AllComponentKeys))
	}
	for _, key := range v1alpha1.AllComponentKeys {
		component, ok := components[key].(map[string]any)
		if !ok || len(component) != 1 || component["enabled"] != true {
			t.Errorf("%s must patch only enabled: true, got %v", key, component)
		}
	}
}

func readResourceCRDSchema(t *testing.T, path string) map[string]any {
	t.Helper()
	crd := readResourceYAML(t, path)
	versions, _, err := unstructured.NestedSlice(crd, "spec", "versions")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range versions {
		version := entry.(map[string]any)
		if version["name"] != "v1alpha1" {
			continue
		}
		schema, found, err := unstructured.NestedMap(version, "schema", "openAPIV3Schema")
		if err != nil || !found {
			t.Fatalf("v1alpha1 schema is missing: %v", err)
		}
		return schema
	}
	t.Fatal("v1alpha1 version is missing")
	return nil
}

func assertComponentResourceSchema(t *testing.T, schema map[string]any, key string) {
	t.Helper()
	path := "spec.components." + key
	component := resourceSchemaAt(t, schema, path)
	properties := component["properties"].(map[string]any)
	if _, found := properties["state"]; found {
		t.Error("removed component state input remains in the schema")
	}
	enabled := resourceSchemaAt(t, schema, path+".enabled")
	if enabled["type"] != "boolean" || enabled["default"] != false {
		t.Errorf("enabled must have boolean type and false default: %v", enabled)
	}
	assertResourceOptional(t, component, "enabled")
	assertResourceOptional(t, component, "manager")
	manager := resourceSchemaAt(t, schema, path+".manager")
	assertResourceOptional(t, manager, "resources")
	resources := resourceSchemaAt(t, schema, path+".manager.resources")
	if resources["type"] != "object" {
		t.Errorf("resources must be an object: %v", resources)
	}
	assertNoResourceDefaults(t, resources)
	for _, field := range []string{"requests", "limits"} {
		resourceSchemaAt(t, schema, path+".manager.resources."+field)
	}
}

func readResourceYAML(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", filepath.FromSlash(path)))
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := yaml.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	return object
}

func resourceSchemaAt(t *testing.T, schema map[string]any, path string) map[string]any {
	t.Helper()
	for _, name := range strings.Split(path, ".") {
		var found bool
		var err error
		schema, found, err = unstructured.NestedMap(schema, "properties", name)
		if err != nil || !found {
			t.Fatalf("schema does not contain %s: %v", path, err)
		}
	}
	return schema
}

func assertResourceOptional(t *testing.T, schema map[string]any, field string) {
	t.Helper()
	required, _, err := unstructured.NestedStringSlice(schema, "required")
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(required, field) {
		t.Errorf("%s must be optional", field)
	}
}

func assertNoResourceDefaults(t *testing.T, node any) {
	t.Helper()
	switch value := node.(type) {
	case map[string]any:
		if _, found := value["default"]; found {
			t.Error("resource schema must not duplicate packaged defaults")
		}
		for _, child := range value {
			assertNoResourceDefaults(t, child)
		}
	case []any:
		for _, child := range value {
			assertNoResourceDefaults(t, child)
		}
	}
}

func assertResourceDefaultExample(t *testing.T, example map[string]any) {
	t.Helper()
	if example["apiVersion"] != "workloadavailability.medik8s.io/v1alpha1" ||
		example["kind"] != "WorkloadAvailabilityConfig" {
		t.Errorf("unexpected example identity: %v/%v", example["apiVersion"], example["kind"])
	}
	name, _, err := unstructured.NestedString(example, "metadata", "name")
	if err != nil || name != "cluster" {
		t.Errorf("example must use singleton name cluster: %q (%v)", name, err)
	}
	components, _, err := unstructured.NestedMap(example, "spec", "components")
	if err != nil {
		t.Fatal(err)
	}
	if len(components) != len(v1alpha1.AllComponentKeys) {
		t.Errorf("example has %d components, want %d", len(components), len(v1alpha1.AllComponentKeys))
	}
	for _, key := range v1alpha1.AllComponentKeys {
		component, ok := components[key].(map[string]any)
		if !ok || len(component) != 1 || component["enabled"] != false {
			t.Errorf("default %s must contain only enabled: false, got %v", key, component)
		}
	}
}
