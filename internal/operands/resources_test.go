package operands

import (
	"reflect"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/medik8s/workload-availability-operator/internal/components"
)

func resourceList(cpu, memory string) corev1.ResourceList {
	out := corev1.ResourceList{}
	if cpu != "" {
		out[corev1.ResourceCPU] = resource.MustParse(cpu)
	}
	if memory != "" {
		out[corev1.ResourceMemory] = resource.MustParse(memory)
	}
	return out
}

func TestMergeResourcesRejectsLimitBelowDefaultRequest(t *testing.T) {
	defaults := corev1.ResourceRequirements{Requests: resourceList("", "64Mi")}
	overrides := corev1.ResourceRequirements{Limits: resourceList("", "32Mi")}
	_, err := mergeResources(defaults, overrides)
	if err == nil {
		t.Fatal("accepted a limit below the effective request")
	}
}

func TestMergeResources(t *testing.T) {
	defaults := corev1.ResourceRequirements{
		Requests: resourceList("100m", "64Mi"),
		Limits:   resourceList("500m", "128Mi"),
	}
	for _, tc := range []struct {
		name                                             string
		overrides                                        corev1.ResourceRequirements
		requestCPU, requestMemory, limitCPU, limitMemory string
		wantError                                        string
	}{
		{name: "empty", requestCPU: "100m", requestMemory: "64Mi", limitCPU: "500m", limitMemory: "128Mi"},
		{name: "empty maps", overrides: corev1.ResourceRequirements{Requests: corev1.ResourceList{}, Limits: corev1.ResourceList{}}, requestCPU: "100m", requestMemory: "64Mi", limitCPU: "500m", limitMemory: "128Mi"},
		{name: "CPU request", overrides: corev1.ResourceRequirements{Requests: resourceList("200m", "")}, requestCPU: "200m", requestMemory: "64Mi", limitCPU: "500m", limitMemory: "128Mi"},
		{name: "memory limit", overrides: corev1.ResourceRequirements{Limits: resourceList("", "256Mi")}, requestCPU: "100m", requestMemory: "64Mi", limitCPU: "500m", limitMemory: "256Mi"},
		{name: "full", overrides: corev1.ResourceRequirements{Requests: resourceList("200m", "100Mi"), Limits: resourceList("1", "512Mi")}, requestCPU: "200m", requestMemory: "100Mi", limitCPU: "1", limitMemory: "512Mi"},
		{name: "equal equivalent units", overrides: corev1.ResourceRequirements{Requests: resourceList("0.5", "134217728")}, requestCPU: "500m", requestMemory: "128Mi", limitCPU: "500m", limitMemory: "128Mi"},
		{name: "zero request", overrides: corev1.ResourceRequirements{Requests: resourceList("0", "0")}, requestCPU: "0", requestMemory: "0", limitCPU: "500m", limitMemory: "128Mi"},
		{name: "zero limit and request", overrides: corev1.ResourceRequirements{Requests: resourceList("0", ""), Limits: resourceList("0", "")}, requestCPU: "0", requestMemory: "64Mi", limitCPU: "0", limitMemory: "128Mi"},
		{name: "request above inherited limit", overrides: corev1.ResourceRequirements{Requests: resourceList("600m", "")}, wantError: "requests.cpu: effective request 600m exceeds effective limit 500m"},
		{name: "limit below inherited request", overrides: corev1.ResourceRequirements{Limits: resourceList("", "32Mi")}, wantError: "requests.memory: effective request 64Mi exceeds effective limit 32Mi"},
		{name: "negative CPU request", overrides: corev1.ResourceRequirements{Requests: resourceList("-1", "")}, wantError: "requests.cpu"},
		{name: "negative memory request", overrides: corev1.ResourceRequirements{Requests: resourceList("", "-1Mi")}, wantError: "requests.memory"},
		{name: "negative CPU limit", overrides: corev1.ResourceRequirements{Limits: resourceList("-1", "")}, wantError: "limits.cpu"},
		{name: "negative memory limit", overrides: corev1.ResourceRequirements{Limits: resourceList("", "-1Mi")}, wantError: "limits.memory"},
		{name: "unsupported request", overrides: corev1.ResourceRequirements{Requests: corev1.ResourceList{corev1.ResourceEphemeralStorage: resource.MustParse("1Gi")}}, wantError: "requests.ephemeral-storage"},
		{name: "unsupported limit", overrides: corev1.ResourceRequirements{Limits: corev1.ResourceList{"example.test/device": resource.MustParse("1")}}, wantError: "limits.example.test/device"},
		{name: "claims", overrides: corev1.ResourceRequirements{Claims: []corev1.ResourceClaim{{Name: "device"}}}, wantError: "claims"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			beforeDefaults, beforeOverrides := defaults.DeepCopy(), tc.overrides.DeepCopy()
			got, err := mergeResources(defaults, tc.overrides)
			if !reflect.DeepEqual(&defaults, beforeDefaults) || !reflect.DeepEqual(&tc.overrides, beforeOverrides) {
				t.Fatal("merge modified its inputs")
			}
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("error = %v, want %q", err, tc.wantError)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			for _, quantities := range []struct {
				label       string
				got         corev1.ResourceList
				cpu, memory string
			}{
				{"requests", got.Requests, tc.requestCPU, tc.requestMemory}, {"limits", got.Limits, tc.limitCPU, tc.limitMemory},
			} {
				for name, want := range map[corev1.ResourceName]string{corev1.ResourceCPU: quantities.cpu, corev1.ResourceMemory: quantities.memory} {
					actual, exists := quantities.got[name]
					if !exists || actual.Cmp(resource.MustParse(want)) != 0 {
						t.Errorf("%s.%s = %v, want %s", quantities.label, name, actual, want)
					}
				}
			}
			got.Requests[corev1.ResourceCPU] = resource.MustParse("42")
			got.Limits[corev1.ResourceMemory] = resource.MustParse("42Gi")
			if !reflect.DeepEqual(&defaults, beforeDefaults) || !reflect.DeepEqual(&tc.overrides, beforeOverrides) {
				t.Fatal("result shares resource maps with inputs")
			}
		})
	}
}

func TestMergeResourcesAbsentDefaults(t *testing.T) {
	got, err := mergeResources(corev1.ResourceRequirements{}, corev1.ResourceRequirements{Requests: resourceList("0", "")})
	if err != nil {
		t.Fatal(err)
	}
	value, exists := got.Requests[corev1.ResourceCPU]
	if !exists || !value.IsZero() || len(got.Limits) != 0 || len(got.Requests) != 1 {
		t.Fatalf("unexpected resources: %v", got)
	}
}

func TestMergeResourcesPreservesOtherPackagedResources(t *testing.T) {
	defaults := corev1.ResourceRequirements{Requests: corev1.ResourceList{corev1.ResourceEphemeralStorage: resource.MustParse("1Gi")}}
	got, err := mergeResources(defaults, corev1.ResourceRequirements{Requests: resourceList("100m", "")})
	if err != nil {
		t.Fatal(err)
	}
	value, exists := got.Requests[corev1.ResourceEphemeralStorage]
	if !exists || value.Cmp(resource.MustParse("1Gi")) != 0 {
		t.Fatalf("lost packaged resource: %v", got)
	}
}

func managerFixture() (components.Definition, []*unstructured.Unstructured) {
	def := components.SBR()
	deployment := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "apps/v1", "kind": "Deployment", "metadata": map[string]any{"name": def.ManagerDeployment},
		"spec": map[string]any{"template": map[string]any{"spec": map[string]any{
			"initContainers": []any{map[string]any{"name": "init", "resources": map[string]any{"requests": map[string]any{"cpu": "1m"}}}},
			"containers": []any{
				map[string]any{"name": "sidecar", "resources": map[string]any{"limits": map[string]any{"memory": "20Mi"}}},
				map[string]any{"name": "manager", "image": "example.test/manager:tag", "customField": "preserve", "resources": map[string]any{
					"requests": map[string]any{"cpu": "10m", "memory": "64Mi"}, "limits": map[string]any{"cpu": "500m", "memory": "128Mi"},
				}},
			},
		}}},
	}}
	return def, []*unstructured.Unstructured{deployment}
}

func copyObjects(objects []*unstructured.Unstructured) []*unstructured.Unstructured {
	out := make([]*unstructured.Unstructured, len(objects))
	for i, object := range objects {
		out[i] = object.DeepCopy()
	}
	return out
}

func TestApplyManagerResourcesChangesNamedManagerOnly(t *testing.T) {
	def, objects := managerFixture()
	expected := copyObjects(objects)
	expectedContainers, _, _ := unstructured.NestedSlice(expected[0].Object, "spec", "template", "spec", "containers")
	expectedContainers[1].(map[string]any)["resources"].(map[string]any)["requests"].(map[string]any)["cpu"] = "200m"
	if err := unstructured.SetNestedSlice(expected[0].Object, expectedContainers, "spec", "template", "spec", "containers"); err != nil {
		t.Fatal(err)
	}
	overrides := &corev1.ResourceRequirements{Requests: resourceList("200m", "")}
	if err := ApplyManagerResources(def, objects, overrides); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(objects, expected) {
		t.Fatalf("changed unrelated object fields: got %v, want %v", objects, expected)
	}
}

func TestApplyManagerResourcesNoOverride(t *testing.T) {
	for _, overrides := range []*corev1.ResourceRequirements{nil, {}, {Requests: corev1.ResourceList{}, Limits: corev1.ResourceList{}}} {
		def, objects := managerFixture()
		before := copyObjects(objects)
		if err := ApplyManagerResources(def, objects, overrides); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(objects, before) {
			t.Fatal("omitted or empty override changed rendered objects")
		}
	}
	if err := ApplyManagerResources(components.Definition{}, nil, nil); err != nil {
		t.Fatalf("nil override selected a target: %v", err)
	}
}

func TestApplyManagerResourcesErrorsLeaveObjectsUnchanged(t *testing.T) {
	for _, tc := range []struct {
		name      string
		modify    func(*components.Definition, *[]*unstructured.Unstructured)
		overrides corev1.ResourceRequirements
		want      string
	}{
		{name: "default request conflict", overrides: corev1.ResourceRequirements{Limits: resourceList("", "32Mi")}, want: "spec.components.storageBasedRemediation.manager.resources.requests.memory: effective request 64Mi exceeds effective limit 32Mi"},
		{name: "inherited limit conflict", overrides: corev1.ResourceRequirements{Requests: resourceList("600m", "")}, want: "spec.components.storageBasedRemediation.manager.resources.requests.cpu"},
		{name: "negative", overrides: corev1.ResourceRequirements{Requests: resourceList("-1", "")}, want: "spec.components.storageBasedRemediation.manager.resources.requests.cpu"},
		{name: "unsupported", overrides: corev1.ResourceRequirements{Limits: corev1.ResourceList{corev1.ResourceEphemeralStorage: resource.MustParse("1Gi")}}, want: "spec.components.storageBasedRemediation.manager.resources.limits.ephemeral-storage"},
		{name: "claims", overrides: corev1.ResourceRequirements{Claims: []corev1.ResourceClaim{{Name: "device"}}}, want: "spec.components.storageBasedRemediation.manager.resources.claims"},
		{name: "missing Deployment", modify: func(_ *components.Definition, objs *[]*unstructured.Unstructured) { (*objs)[0].SetName("other") }, want: "Deployment/sbr-operator-controller-manager"},
		{name: "duplicate Deployment", modify: func(_ *components.Definition, objs *[]*unstructured.Unstructured) {
			*objs = append(*objs, (*objs)[0].DeepCopy())
		}, want: "Deployment/sbr-operator-controller-manager"},
		{name: "missing container", modify: func(def *components.Definition, _ *[]*unstructured.Unstructured) { def.ManagerContainer = "absent" }, want: "container/absent"},
		{name: "duplicate container", modify: func(_ *components.Definition, objs *[]*unstructured.Unstructured) {
			containers, _, _ := unstructured.NestedSlice((*objs)[0].Object, "spec", "template", "spec", "containers")
			containers = append(containers, containers[1])
			_ = unstructured.SetNestedSlice((*objs)[0].Object, containers, "spec", "template", "spec", "containers")
		}, want: "container/manager"},
		{name: "malformed resources", modify: func(_ *components.Definition, objs *[]*unstructured.Unstructured) {
			containers, _, _ := unstructured.NestedSlice((*objs)[0].Object, "spec", "template", "spec", "containers")
			containers[1].(map[string]any)["resources"] = "invalid"
			_ = unstructured.SetNestedSlice((*objs)[0].Object, containers, "spec", "template", "spec", "containers")
		}, want: "Deployment/sbr-operator-controller-manager container/manager"},
		{name: "malformed quantity", modify: func(_ *components.Definition, objs *[]*unstructured.Unstructured) {
			containers, _, _ := unstructured.NestedSlice((*objs)[0].Object, "spec", "template", "spec", "containers")
			containers[1].(map[string]any)["resources"] = map[string]any{"requests": map[string]any{"cpu": "invalid"}}
			_ = unstructured.SetNestedSlice((*objs)[0].Object, containers, "spec", "template", "spec", "containers")
		}, want: "Deployment/sbr-operator-controller-manager container/manager"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			def, objects := managerFixture()
			if tc.modify != nil {
				tc.modify(&def, &objects)
			}
			before := copyObjects(objects)
			err := ApplyManagerResources(def, objects, &tc.overrides)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %v, want %q", err, tc.want)
			}
			if !strings.Contains(err.Error(), "spec.components.storageBasedRemediation.manager.resources") {
				t.Fatalf("missing configuration path: %v", err)
			}
			if !reflect.DeepEqual(objects, before) {
				t.Fatal("invalid override modified rendered objects")
			}
		})
	}
}
