package operands

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestLatestPullPolicyPreservesOtherImages(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]any{
		"kind": "Deployment",
		"spec": map[string]any{"template": map[string]any{"spec": map[string]any{
			"containers": []any{
				map[string]any{"image": "example.test/selected:latest", "imagePullPolicy": "IfNotPresent"},
				map[string]any{"image": "example.test/other:latest", "imagePullPolicy": "Never"},
				map[string]any{"image": "example.test/release@sha256:abc", "imagePullPolicy": "IfNotPresent"},
			},
			"initContainers": []any{map[string]any{"image": "example.test/selected:latest"}},
		}}}}}
	if err := setLatestPullPolicy(obj, map[string]bool{"example.test/selected:latest": true}); err != nil {
		t.Fatal(err)
	}
	containers, _, _ := unstructured.NestedSlice(obj.Object, "spec", "template", "spec", "containers")
	for i, want := range []string{"Always", "Never", "IfNotPresent"} {
		if got := containers[i].(map[string]any)["imagePullPolicy"]; got != want {
			t.Errorf("container %d policy = %v, want %s", i, got, want)
		}
	}
	init, _, _ := unstructured.NestedSlice(obj.Object, "spec", "template", "spec", "initContainers")
	if got := init[0].(map[string]any)["imagePullPolicy"]; got != "Always" {
		t.Errorf("init policy = %v", got)
	}
}

func TestLatestPullPolicyRejectsMalformedContainers(t *testing.T) {
	for _, value := range []any{map[string]any{}, []any{"bad"}, []any{map[string]any{"image": int64(3)}}} {
		obj := &unstructured.Unstructured{Object: map[string]any{
			"kind": "Deployment",
			"spec": map[string]any{"template": map[string]any{"spec": map[string]any{"containers": value}}}}}
		if err := setLatestPullPolicy(obj, map[string]bool{"example.test/image:latest": true}); err == nil {
			t.Errorf("accepted malformed containers: %v", value)
		}
	}
}
