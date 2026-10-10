package operands_test

import (
	"reflect"
	"strings"
	"testing"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/components"
	"github.com/jwmatthews/wao_poc/internal/images"
	"github.com/jwmatthews/wao_poc/internal/operands"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

const testNamespace = "wao-ns"

func testImages() images.Set {
	s := images.Set{}
	for _, k := range images.Required {
		s[k] = "example.test/" + strings.ToLower(k) + "@sha256:0000000000000000000000000000000000000000000000000000000000000000"
	}
	return s
}

func find(t *testing.T, objs []*unstructured.Unstructured, kind, name string) *unstructured.Unstructured {
	for _, o := range objs {
		if o.GetKind() == kind && o.GetName() == name {
			return o
		}
	}
	t.Fatalf("%s/%s not rendered", kind, name)
	return nil
}

func TestRenderNHCReplacesNamespaceImagesAndLabels(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	objs, err := operands.Render(def, testNamespace, testImages())
	if err != nil {
		t.Fatal(err)
	}
	dep := find(t, objs, "Deployment", "node-healthcheck-controller-manager")
	containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	image := containers[0].(map[string]interface{})["image"].(string)
	if image != testImages().Get(images.NHCManager) {
		t.Fatalf("manager image = %q", image)
	}
	if strings.Contains(image, ":v0.12.0") {
		t.Fatalf("upstream tag was not replaced: %q", image)
	}
	for _, o := range objs {
		if o.GetLabels()[operands.LabelManagedBy] != operands.ManagedByValue || o.GetLabels()[operands.LabelComponent] != def.Key {
			t.Errorf("%s/%s missing WAO labels: %v", o.GetKind(), o.GetName(), o.GetLabels())
		}
		if operands.IsNamespaced(o.GetKind()) && o.GetNamespace() != testNamespace {
			t.Errorf("%s/%s namespace = %q", o.GetKind(), o.GetName(), o.GetNamespace())
		}
	}
	vw := find(t, objs, "ValidatingWebhookConfiguration", "node-healthcheck-validating-webhook-configuration")
	hooks, _, _ := unstructured.NestedSlice(vw.Object, "webhooks")
	svc := hooks[0].(map[string]interface{})["clientConfig"].(map[string]interface{})["service"].(map[string]interface{})
	if svc["namespace"] != testNamespace || svc["name"] != "node-healthcheck-webhook-service" {
		t.Fatalf("webhook service = %v", svc)
	}
}

func TestRenderOrdersRBACBeforeWorkloadsAndWebhooksLast(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	objs, err := operands.Render(def, testNamespace, testImages())
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	for i, o := range objs {
		if _, seen := pos[o.GetKind()]; !seen {
			pos[o.GetKind()] = i
		}
	}
	if pos["ServiceAccount"] >= pos["ClusterRole"] ||
		pos["ClusterRole"] >= pos["ClusterRoleBinding"] ||
		pos["Service"] >= pos["Deployment"] ||
		pos["Deployment"] >= pos["ValidatingWebhookConfiguration"] ||
		pos["Deployment"] >= pos["MutatingWebhookConfiguration"] {
		t.Fatalf("unexpected order: %v", pos)
	}
}

func TestRenderSNRReplacesAgentImageEnv(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeySelfNodeRemediation)
	objs, err := operands.Render(def, testNamespace, testImages())
	if err != nil {
		t.Fatal(err)
	}
	dep := find(t, objs, "Deployment", "self-node-remediation-controller-manager")
	containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	env, _, _ := unstructured.NestedSlice(containers[0].(map[string]interface{}), "env")
	found := false
	for _, e := range env {
		m := e.(map[string]interface{})
		if m["name"] == "SELF_NODE_REMEDIATION_IMAGE" {
			found = true
			if m["value"] != testImages().Get(images.SNRManager) {
				t.Fatalf("SELF_NODE_REMEDIATION_IMAGE = %v", m["value"])
			}
		}
	}
	if !found {
		t.Fatal("SELF_NODE_REMEDIATION_IMAGE env not rendered")
	}
	crb := find(t, objs, "ClusterRoleBinding", "self-node-remediation-controller-manager")
	subjects, _, _ := unstructured.NestedSlice(crb.Object, "subjects")
	if subjects[0].(map[string]interface{})["namespace"] != testNamespace {
		t.Fatalf("subject namespace not rewritten: %v", subjects[0])
	}
}

func TestRenderFailsWhenImageMissing(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyStorageBasedRemediation)
	imgs := testImages()
	delete(imgs, images.SBRAgent)
	if _, err := operands.Render(def, "wao-ns", imgs); err == nil || !strings.Contains(err.Error(), images.SBRAgent) {
		t.Fatalf("expected error naming %s, got %v", images.SBRAgent, err)
	}
}

func TestRenderLeavesNoPlaceholder(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, "wao-ns", testImages())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range objs {
			b, _ := o.MarshalJSON()
			if strings.Contains(string(b), operands.NamespacePlaceholder) {
				t.Errorf("%s: %s/%s still contains placeholder", def.Key, o.GetKind(), o.GetName())
			}
		}
	}
}

func TestRenderReplacesEveryUpstreamImage(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, "wao-ns", testImages())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range objs {
			b, _ := o.MarshalJSON()
			for _, img := range def.Images {
				if strings.Contains(string(b), img.Original) {
					t.Errorf("%s: %s/%s still references upstream image %s", def.Key, o.GetKind(), o.GetName(), img.Original)
				}
			}
			if strings.Contains(string(b), "quay.io/medik8s/") {
				t.Errorf("%s: %s/%s references an unbound upstream image", def.Key, o.GetKind(), o.GetName())
			}
		}
	}
}

// olmNamespacesRule is the rule OLM appends to the cluster-wide copy of a CSV's namespaced permissions.
var olmNamespacesRule = map[string]interface{}{
	"apiGroups": []interface{}{""},
	"resources": []interface{}{"namespaces"},
	"verbs":     []interface{}{"get", "list", "watch"},
}

// OLM grants a CSV's namespaced permissions cluster-wide for an AllNamespaces OperatorGroup and appends
// get/list/watch on namespaces; every component's manager ServiceAccount must get the same ClusterRole and binding.
func TestRenderGrantsCSVNamespacedPermissionsClusterWide(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, "wao-ns", testImages())
		if err != nil {
			t.Fatal(err)
		}
		sa := def.Deployments[0]
		name := sa + "-all-namespaces"
		role := find(t, objs, "Role", sa)
		cr := find(t, objs, "ClusterRole", name)
		roleRules, _, _ := unstructured.NestedSlice(role.Object, "rules")
		crRules, _, _ := unstructured.NestedSlice(cr.Object, "rules")
		want := append(append([]interface{}{}, roleRules...), olmNamespacesRule)
		if len(roleRules) == 0 || !reflect.DeepEqual(crRules, want) {
			t.Errorf("%s: ClusterRole/%s rules %v, want Role/%s rules plus OLM's namespaces rule %v", def.Key, name, crRules, sa, want)
		}
		crb := find(t, objs, "ClusterRoleBinding", name)
		ref, _, _ := unstructured.NestedStringMap(crb.Object, "roleRef")
		subjects, _, _ := unstructured.NestedSlice(crb.Object, "subjects")
		if ref["kind"] != "ClusterRole" || ref["name"] != name || len(subjects) != 1 {
			t.Fatalf("%s: ClusterRoleBinding/%s = %v %v", def.Key, name, ref, subjects)
		}
		s := subjects[0].(map[string]interface{})
		if s["kind"] != "ServiceAccount" || s["name"] != sa || s["namespace"] != "wao-ns" {
			t.Errorf("%s: ClusterRoleBinding/%s subject = %v", def.Key, name, s)
		}
		for _, o := range []*unstructured.Unstructured{cr, crb} {
			if o.GetLabels()[operands.LabelManagedBy] != operands.ManagedByValue || o.GetLabels()[operands.LabelComponent] != def.Key {
				t.Errorf("%s/%s missing WAO labels: %v", o.GetKind(), o.GetName(), o.GetLabels())
			}
		}
	}
}

// Issue #4: the console backend is an NHC operand with its own pinned image (spec P2, P6).
func TestRenderNHCConsoleBackend(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	if want := []string{"node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"}; !reflect.DeepEqual(def.Deployments, want) {
		t.Fatalf("NHC deployments = %v, want %v", def.Deployments, want)
	}
	objs, err := operands.Render(def, testNamespace, testImages())
	if err != nil {
		t.Fatal(err)
	}
	dep := find(t, objs, "Deployment", "node-healthcheck-node-remediation-console-plugin")
	containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	if img := containers[0].(map[string]interface{})["image"]; img != testImages().Get(images.NHCConsole) {
		t.Fatalf("console image = %v, want the pinned %s", img, images.NHCConsole)
	}
	find(t, objs, "Service", "node-healthcheck-node-remediation-console-plugin")
	sa := find(t, objs, "ServiceAccount", "node-healthcheck-console-plugin")
	if v, ok, _ := unstructured.NestedBool(sa.Object, "automountServiceAccountToken"); !ok || v {
		t.Fatalf("console ServiceAccount automountServiceAccountToken = %v,%v, want false", v, ok)
	}
}
