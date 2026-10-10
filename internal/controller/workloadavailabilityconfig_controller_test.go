package controller

import (
	"context"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
	"github.com/jwmatthews/wao_poc/internal/operands"
)

const ns = "wao-test"

func getWAC(ctx context.Context) *v1alpha1.WorkloadAvailabilityConfig {
	w := &v1alpha1.WorkloadAvailabilityConfig{}
	Expect(k8sClient.Get(ctx, types.NamespacedName{Name: v1alpha1.SingletonName}, w)).To(Succeed())
	return w
}

func component(w *v1alpha1.WorkloadAvailabilityConfig, key string) *v1alpha1.ComponentStatus {
	for i := range w.Status.Components {
		if w.Status.Components[i].Name == key {
			return &w.Status.Components[i]
		}
	}
	return nil
}

func setState(ctx context.Context, key string, state v1alpha1.ComponentState) {
	Eventually(func() error {
		w := getWAC(ctx)
		switch key {
		case v1alpha1.ComponentKeyNodeHealthCheck:
			w.Spec.Components.NodeHealthCheck.State = state
		case v1alpha1.ComponentKeySelfNodeRemediation:
			w.Spec.Components.SelfNodeRemediation.State = state
		case v1alpha1.ComponentKeyStorageBasedRemediation:
			w.Spec.Components.StorageBasedRemediation.State = state
		case v1alpha1.ComponentKeyFenceAgentsRemediation:
			w.Spec.Components.FenceAgentsRemediation.State = state
		case v1alpha1.ComponentKeyMachineDeletionRemediation:
			w.Spec.Components.MachineDeletionRemediation.State = state
		case v1alpha1.ComponentKeyNodeMaintenance:
			w.Spec.Components.NodeMaintenance.State = state
		}
		return k8sClient.Update(ctx, w)
	}).Should(Succeed())
}

var _ = Describe("WorkloadAvailabilityConfig controller", Ordered, func() {
	ctx := context.Background()

	It("rejects a non-singleton name via CEL", func() {
		bad := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: "other"}}
		err := k8sClient.Create(ctx, bad)
		Expect(apierrors.IsInvalid(err)).To(BeTrue(), "got %v", err)
		Expect(err.Error()).To(ContainSubstring("singleton"))
	})

	It("reports Available with every component Disabled and creates nothing", func() {
		Expect(k8sClient.Create(ctx, &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName}})).To(Succeed())
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			g.Expect(meta.IsStatusConditionTrue(w.Status.Conditions, v1alpha1.ConditionAvailable)).To(BeTrue())
			g.Expect(w.Status.Components).To(HaveLen(6))
			for _, c := range w.Status.Components {
				g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
			}
			g.Expect(w.Status.InstallNamespace).To(Equal(ns))
			g.Expect(w.Status.ReleaseSet).To(HaveLen(len(images.Required)))
			g.Expect(w.Finalizers).To(ContainElement(Finalizer))
		}).Should(Succeed())
		deps := &appsv1.DeploymentList{}
		Expect(k8sClient.List(ctx, deps, client.InNamespace(ns))).To(Succeed())
		Expect(deps.Items).To(BeEmpty())
	})

	It("does not rewrite status when nothing changes", func() {
		rv := getWAC(ctx).ResourceVersion
		Consistently(func() string { return getWAC(ctx).ResourceVersion }, 5*time.Second, 250*time.Millisecond).Should(Equal(rv))
	})

	It("installs the NHC operand when enabled", func() {
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateEnabled)
		// Status is written after every operand object has been applied, so wait for it first.
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck)
			g.Expect(c).NotTo(BeNil())
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseProgressing)) // envtest has no kubelet or service-ca
			g.Expect(c.Deployments).To(HaveLen(2))                          // the manager and the console backend (issue #4)
			g.Expect(c.AdmissionReady).To(Equal(ptr.To(false)))
		}).Should(Succeed())
		dep := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, dep)).To(Succeed())
		Expect(dep.Spec.Template.Spec.Containers[0].Image).To(Equal(testImages().Get(images.NHCManager)))
		Expect(dep.Labels[operands.LabelManagedBy]).To(Equal(operands.ManagedByValue))
		Expect(dep.OwnerReferences).To(HaveLen(1))
		Expect(dep.OwnerReferences[0].Kind).To(Equal("WorkloadAvailabilityConfig"))
		Expect(*dep.OwnerReferences[0].Controller).To(BeTrue())

		console := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-node-remediation-console-plugin"}, console)).To(Succeed())
		Expect(console.Spec.Template.Spec.Containers[0].Image).To(Equal(testImages().Get(images.NHCConsole)))
		Expect(console.Labels[operands.LabelComponent]).To(Equal(v1alpha1.ComponentKeyNodeHealthCheck))
		cm := &corev1.ConfigMap{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, cm)).To(Succeed())
		Expect(cm.Annotations).To(HaveKeyWithValue("service.beta.openshift.io/inject-cabundle", "true"))
		Expect(cm.Labels[operands.LabelManagedBy]).To(Equal(operands.ManagedByValue))
		Expect(cm.OwnerReferences).To(HaveLen(1))
		Expect(cm.Data).To(BeEmpty())
		consoleSA := &corev1.ServiceAccount{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-console-plugin"}, consoleSA)).To(Succeed())
		Expect(consoleSA.AutomountServiceAccountToken).To(Equal(ptr.To(false)))

		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager"}, &rbacv1.ClusterRole{})).To(Succeed())
		// OLM AllNamespaces behaviour: the CSV's namespaced permissions are also granted cluster-wide,
		// with OLM's get/list/watch rule on namespaces appended.
		allNSRole := &rbacv1.ClusterRole{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager-all-namespaces"}, allNSRole)).To(Succeed())
		nsRole := &rbacv1.Role{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, nsRole)).To(Succeed())
		Expect(allNSRole.Rules).To(Equal(append(append([]rbacv1.PolicyRule{}, nsRole.Rules...),
			rbacv1.PolicyRule{APIGroups: []string{""}, Resources: []string{"namespaces"}, Verbs: []string{"get", "list", "watch"}})))
		allNS := &rbacv1.ClusterRoleBinding{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager-all-namespaces"}, allNS)).To(Succeed())
		Expect(allNS.Subjects).To(ConsistOf(rbacv1.Subject{Kind: "ServiceAccount", Name: "node-healthcheck-controller-manager", Namespace: ns}))
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, &corev1.ServiceAccount{})).To(Succeed())
		vw := &admissionregistrationv1.ValidatingWebhookConfiguration{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-validating-webhook-configuration"}, vw)).To(Succeed())
		Expect(vw.Webhooks[0].ClientConfig.Service.Namespace).To(Equal(ns))
		Expect(vw.Annotations["service.beta.openshift.io/inject-cabundle"]).To(Equal("true"))
	})

	It("preserves the service-ca injected CA data across reconciles", func() {
		// service-ca writes service-ca.crt with its own field manager. WAO applies no data and forces ownership
		// of what it does apply, so the injected key must survive the next apply (spec P9).
		injected := &corev1.ConfigMap{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "ConfigMap"},
			ObjectMeta: metav1.ObjectMeta{Name: "node-healthcheck-ca-bundle", Namespace: ns},
			Data:       map[string]string{"service-ca.crt": "-----BEGIN CERTIFICATE-----\nenvtest\n-----END CERTIFICATE-----\n"}}
		Expect(k8sClient.Patch(ctx, injected, client.Apply, client.FieldOwner("service-ca-operator"))).To(Succeed())
		// Deleting an owned Deployment makes WAO re-apply every NHC object, the ConfigMap included.
		Expect(k8sClient.Delete(ctx, &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "node-healthcheck-node-remediation-console-plugin", Namespace: ns}})).To(Succeed())
		Eventually(func() error {
			return k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-node-remediation-console-plugin"}, &appsv1.Deployment{})
		}).Should(Succeed())
		cm := &corev1.ConfigMap{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, cm)).To(Succeed())
		Expect(cm.Data).To(HaveKey("service-ca.crt"))
		Expect(cm.Annotations).To(HaveKeyWithValue("service.beta.openshift.io/inject-cabundle", "true"))
	})

	It("recreates the CA ConfigMap when it is deleted", func() {
		cm := &corev1.ConfigMap{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, cm)).To(Succeed())
		uid := cm.UID
		Expect(k8sClient.Delete(ctx, cm)).To(Succeed())
		Eventually(func(g Gomega) {
			fresh := &corev1.ConfigMap{}
			g.Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, fresh)).To(Succeed())
			g.Expect(fresh.UID).NotTo(Equal(uid))
		}).Should(Succeed())
	})

	It("refuses to adopt a foreign object with the same name", func() {
		foreign := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "sbr-operator-controller-manager", Namespace: ns},
			Spec: appsv1.DeploymentSpec{Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "foreign"}},
				Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "foreign"}},
					Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "x", Image: "example.test/foreign"}}}}}}
		Expect(k8sClient.Create(ctx, foreign)).To(Succeed())
		setState(ctx, v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			c := component(w, v1alpha1.ComponentKeyStorageBasedRemediation)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDegraded))
			g.Expect(c.Message).To(ContainSubstring("not managed by"))
			g.Expect(meta.IsStatusConditionTrue(w.Status.Conditions, v1alpha1.ConditionDegraded)).To(BeTrue())
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed())
		Expect(foreign.Spec.Template.Spec.Containers[0].Image).To(Equal("example.test/foreign"))
		setState(ctx, v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyStorageBasedRemediation)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
			g.Expect(c.Message).To(ContainSubstring("foreign"))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed(), "WAO must not delete a foreign object on disable")
		Expect(k8sClient.Delete(ctx, foreign)).To(Succeed()) // test cleanup, not WAO behavior
	})

	It("removes the NHC operand and reports admission unavailable when disabled", func() {
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateDisabled)
		// Status is written after every operand object has been deleted, so wait for it first.
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
			g.Expect(c.AdmissionReady).To(Equal(ptr.To(false)))
			g.Expect(c.Message).To(ContainSubstring("admission"))
		}).Should(Succeed())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}, &appsv1.Deployment{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-validating-webhook-configuration"}, &admissionregistrationv1.ValidatingWebhookConfiguration{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager"}, &rbacv1.ClusterRole{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager-all-namespaces"}, &rbacv1.ClusterRole{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "node-healthcheck-controller-manager-all-namespaces"}, &rbacv1.ClusterRoleBinding{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-node-remediation-console-plugin"}, &appsv1.Deployment{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}, &corev1.ConfigMap{}))).To(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "node-healthcheck-console-plugin"}, &corev1.ServiceAccount{}))).To(BeTrue())
	})

	It("refuses to adopt a foreign CA ConfigMap", func() {
		foreign := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "node-healthcheck-ca-bundle", Namespace: ns}, Data: map[string]string{"service-ca.crt": "foreign"}}
		Expect(k8sClient.Create(ctx, foreign)).To(Succeed())
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDegraded))
			g.Expect(c.Message).To(ContainSubstring("ConfigMap " + ns + "/node-healthcheck-ca-bundle"))
			g.Expect(c.Message).To(ContainSubstring("not managed by"))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed())
		Expect(foreign.Data).To(HaveKeyWithValue("service-ca.crt", "foreign"))
		Expect(foreign.Labels).NotTo(HaveKey(operands.LabelManagedBy))
		setState(ctx, v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeyNodeHealthCheck).Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), foreign)).To(Succeed(), "WAO must not delete a foreign object on disable")
		Expect(k8sClient.Delete(ctx, foreign)).To(Succeed()) // test cleanup, not WAO behavior
	})

	It("reports DisableIncomplete when SNR agents survive a manager-level disable", func() {
		// Simulate what the SNR manager creates at runtime. Do it while SNR is Disabled: once enabled,
		// SNR's Fail-policy webhooks are registered and envtest has no backend to answer them.
		cfg := &unstructured.Unstructured{}
		cfg.SetGroupVersionKind(schema.GroupVersionKind{Group: "self-node-remediation.medik8s.io", Version: "v1alpha1", Kind: "SelfNodeRemediationConfig"})
		cfg.SetName("self-node-remediation-config")
		cfg.SetNamespace(ns)
		Expect(k8sClient.Create(ctx, cfg)).To(Succeed())
		ds := &appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: "self-node-remediation-ds", Namespace: ns,
			OwnerReferences: []metav1.OwnerReference{{APIVersion: "self-node-remediation.medik8s.io/v1alpha1", Kind: "SelfNodeRemediationConfig", Name: cfg.GetName(), UID: cfg.GetUID(), Controller: ptr.To(true)}}},
			Spec: appsv1.DaemonSetSpec{Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": "snr-agent"}},
				Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "snr-agent"}},
					Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "agent", Image: "example.test/agent"}}}}}}
		Expect(k8sClient.Create(ctx, ds)).To(Succeed())

		setState(ctx, v1alpha1.ComponentKeySelfNodeRemediation, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeySelfNodeRemediation).Phase).To(Equal(v1alpha1.ComponentPhaseProgressing))
		}).Should(Succeed())
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "self-node-remediation-controller-manager"}, &appsv1.Deployment{})).To(Succeed())

		setState(ctx, v1alpha1.ComponentKeySelfNodeRemediation, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			c := component(w, v1alpha1.ComponentKeySelfNodeRemediation)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisableIncomplete))
			g.Expect(strings.Join(c.RetainedResources, "\n")).To(ContainSubstring("DaemonSet " + ns + "/self-node-remediation-ds"))
			g.Expect(strings.Join(c.RetainedResources, "\n")).To(ContainSubstring("SelfNodeRemediationConfig " + ns + "/self-node-remediation-config"))
			g.Expect(meta.FindStatusCondition(w.Status.Conditions, v1alpha1.ConditionAvailable).Reason).To(Equal("DisableIncomplete"))
		}).Should(Succeed())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "self-node-remediation-controller-manager"}, &appsv1.Deployment{}))).To(BeTrue())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ds), ds)).To(Succeed(), "WAO must not delete the agent DaemonSet")
		Expect(k8sClient.Delete(ctx, ds)).To(Succeed())
		Expect(k8sClient.Delete(ctx, cfg)).To(Succeed())
	})

	It("installs FAR, MDR and NMO with component-isolated selectors", func() {
		for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
			setState(ctx, key, v1alpha1.ComponentStateEnabled)
		}
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
				g.Expect(component(w, key).Phase).To(Equal(v1alpha1.ComponentPhaseProgressing), key)
			}
		}).Should(Succeed())
		for _, name := range []string{"fence-agents-remediation-controller-manager", "machine-deletion-remediation-controller-manager", "node-maintenance-operator-controller-manager"} {
			Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, &appsv1.Deployment{})).To(Succeed(), name)
		}
		svc := &corev1.Service{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "machine-deletion-remediation-controller-manager-metrics-service"}, svc)).To(Succeed())
		Expect(svc.Spec.Selector).To(HaveKeyWithValue("workloadavailability.medik8s.io/component", v1alpha1.ComponentKeyMachineDeletionRemediation))
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "fence-agents-remediation-mutating-webhook-configuration"}, &admissionregistrationv1.MutatingWebhookConfiguration{})).To(Succeed())
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "node-maintenance-operator-validating-webhook-configuration"}, &admissionregistrationv1.ValidatingWebhookConfiguration{})).To(Succeed())
		for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
			setState(ctx, key, v1alpha1.ComponentStateDisabled)
		}
		Eventually(func(g Gomega) {
			w := getWAC(ctx)
			for _, key := range []string{v1alpha1.ComponentKeyFenceAgentsRemediation, v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance} {
				g.Expect(component(w, key).Phase).To(Equal(v1alpha1.ComponentPhaseDisabled), key)
			}
		}).Should(Succeed())
	})

	It("reports a NodeMaintenance left behind by a disabled NMO as retained", func() {
		// Created while NMO is Disabled: its Fail-policy webhook would otherwise need a backend.
		nm := &unstructured.Unstructured{}
		nm.SetGroupVersionKind(schema.GroupVersionKind{Group: "nodemaintenance.medik8s.io", Version: "v1beta1", Kind: "NodeMaintenance"})
		nm.SetName("wao-test-maintenance")
		Expect(unstructured.SetNestedField(nm.Object, "wao-test-node", "spec", "nodeName")).To(Succeed())
		Expect(unstructured.SetNestedField(nm.Object, "envtest", "spec", "reason")).To(Succeed())
		Expect(k8sClient.Create(ctx, nm)).To(Succeed())
		setState(ctx, v1alpha1.ComponentKeyNodeMaintenance, v1alpha1.ComponentStateEnabled)
		Eventually(func(g Gomega) {
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeyNodeMaintenance).Phase).To(Equal(v1alpha1.ComponentPhaseProgressing))
		}).Should(Succeed())
		setState(ctx, v1alpha1.ComponentKeyNodeMaintenance, v1alpha1.ComponentStateDisabled)
		Eventually(func(g Gomega) {
			c := component(getWAC(ctx), v1alpha1.ComponentKeyNodeMaintenance)
			g.Expect(c.Phase).To(Equal(v1alpha1.ComponentPhaseDisableIncomplete))
			g.Expect(c.RetainedResources).To(ContainElement("nodemaintenance.medik8s.io/v1beta1 NodeMaintenance wao-test-maintenance"))
		}).Should(Succeed())
		Expect(k8sClient.Delete(ctx, nm)).To(Succeed())
		Eventually(func(g Gomega) { // picked up by the periodic re-check
			g.Expect(component(getWAC(ctx), v1alpha1.ComponentKeyNodeMaintenance).Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
		}, 90*time.Second, time.Second).Should(Succeed())
	})

	It("runs the disable sequence and drops its finalizer on deletion", func() {
		setState(ctx, v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentStateEnabled)
		Eventually(func() error {
			return k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "sbr-operator-controller-manager"}, &appsv1.Deployment{})
		}).Should(Succeed())
		Expect(k8sClient.Delete(ctx, getWAC(ctx))).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: v1alpha1.SingletonName}, &v1alpha1.WorkloadAvailabilityConfig{}))
		}).Should(BeTrue())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Namespace: ns, Name: "sbr-operator-controller-manager"}, &appsv1.Deployment{}))).To(BeTrue(), "explicit deletion; envtest has no garbage collector")
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: "sbr-operator-sbr-agent-role"}, &rbacv1.ClusterRole{}))).To(BeTrue())
	})
})
