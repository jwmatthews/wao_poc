package operands_test

import (
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/components"
	"github.com/medik8s/workload-availability-operator/internal/images"
	"github.com/medik8s/workload-availability-operator/internal/operands"
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
	if strings.Contains(image, def.Images[0].Original) {
		t.Fatalf("tagged image was not replaced: %q", image)
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

func TestRenderOrdersServicesBeforeDeploymentsAndWebhooksLast(t *testing.T) {
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
	if pos["Service"] >= pos["Deployment"] ||
		pos["Deployment"] >= pos["ValidatingWebhookConfiguration"] ||
		pos["Deployment"] >= pos["MutatingWebhookConfiguration"] {
		t.Fatalf("unexpected order: %v", pos)
	}
}

// RBAC is created by OLM from the WAO CSV (config/operands/<k>/rbac); the renderer must never emit it.
func TestRenderEmitsNoRBAC(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, testNamespace, testImages())
		if err != nil {
			t.Fatal(err)
		}
		if len(objs) == 0 {
			t.Fatalf("%s: nothing rendered", def.Key)
		}
		for _, o := range objs {
			switch o.GetKind() {
			case "ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding":
				t.Errorf("%s: rendered %s/%s; RBAC belongs to the CSV", def.Key, o.GetKind(), o.GetName())
			}
		}
	}
}

// Design brief D10: all six managers share a namespace, so every pod template and every Service
// selector carries the component label; otherwise MDR's metrics Service would select every manager.
func TestRenderLabelsPodTemplatesAndServiceSelectors(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, testNamespace, testImages())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range objs {
			switch o.GetKind() {
			case "Deployment":
				labels, _, _ := unstructured.NestedStringMap(o.Object, "spec", "template", "metadata", "labels")
				if labels[operands.LabelComponent] != def.Key {
					t.Errorf("%s: Deployment/%s pod template label = %q", def.Key, o.GetName(), labels[operands.LabelComponent])
				}
			case "Service":
				sel, _, _ := unstructured.NestedStringMap(o.Object, "spec", "selector")
				if sel[operands.LabelComponent] != def.Key {
					t.Errorf("%s: Service/%s selector = %v", def.Key, o.GetName(), sel)
				}
			}
		}
	}
}

// Webhook operands mount exactly one service-ca certificate volume at the controller-runtime path.
func TestRenderWebhookOperandsMountOneCertVolume(t *testing.T) {
	for _, def := range components.All() {
		if len(def.Webhooks) == 0 {
			continue
		}
		objs, err := operands.Render(def, testNamespace, testImages())
		if err != nil {
			t.Fatal(err)
		}
		dep := find(t, objs, "Deployment", def.Deployments[0])
		containers, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
		mounts := 0
		for _, c := range containers {
			vms, _, _ := unstructured.NestedSlice(c.(map[string]interface{}), "volumeMounts")
			for _, vm := range vms {
				if vm.(map[string]interface{})["mountPath"] == "/tmp/k8s-webhook-server/serving-certs" {
					mounts++
				}
			}
		}
		if mounts != 1 {
			t.Errorf("%s: %d mounts at the serving-certs path, want 1", def.Key, mounts)
		}
		vols, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "volumes")
		certVols := 0
		for _, v := range vols {
			secret, _, _ := unstructured.NestedString(v.(map[string]interface{}), "secret", "secretName")
			if strings.HasSuffix(secret, "-webhook-server-cert") {
				certVols++
			}
		}
		if certVols != 1 {
			t.Errorf("%s: %d cert volumes, want 1 (volumes: %v)", def.Key, certVols, vols)
		}
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

func TestRenderReplacesEveryOperandImage(t *testing.T) {
	for _, def := range components.All() {
		objs, err := operands.Render(def, "wao-ns", testImages())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range objs {
			b, _ := o.MarshalJSON()
			for _, img := range def.Images {
				if strings.Contains(string(b), img.Original) {
					t.Errorf("%s: %s/%s still references tagged image %s", def.Key, o.GetKind(), o.GetName(), img.Original)
				}
			}
			if strings.Contains(string(b), "quay.io/medik8s/") {
				t.Errorf("%s: %s/%s references an unbound tagged image", def.Key, o.GetKind(), o.GetName())
			}
		}
	}
}
