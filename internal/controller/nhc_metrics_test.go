package controller

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/pem"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/gomega"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/util/cert"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/config"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/components"
)

// Seed an already-ready operand before starting the manager: no Progressing
// requeue is ever scheduled, so only a ConfigMap watch can repair the deletion.
func TestNHCRecreatesDeletedCAWhileAvailable(t *testing.T) {
	g := NewWithT(t)
	env := &envtest.Environment{CRDDirectoryPaths: []string{filepath.Join("..", "..", "config", "crd", "bases")}, ErrorIfCRDPathMissing: true}
	if dir := getFirstFoundEnvTestBinaryDir(); dir != "" {
		env.BinaryAssetsDirectory = dir
	}
	cfg, err := env.Start()
	g.Expect(err).NotTo(HaveOccurred())
	t.Cleanup(func() { g.Expect(env.Stop()).To(Succeed()) })
	s := runtime.NewScheme()
	g.Expect(scheme.AddToScheme(s)).To(Succeed())
	g.Expect(v1alpha1.AddToScheme(s)).To(Succeed())
	c, err := client.New(cfg, client.Options{Scheme: s})
	g.Expect(err).NotTo(HaveOccurred())
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	g.Expect(c.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}})).To(Succeed())
	wac := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName, Finalizers: []string{Finalizer}}}
	wac.Spec.Components.NodeHealthCheck.State = v1alpha1.ComponentStateEnabled
	g.Expect(c.Create(ctx, wac)).To(Succeed())
	r := &WorkloadAvailabilityConfigReconciler{Client: c, Scheme: s, Namespace: ns, Images: testImages()}
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	_, err = r.ensureEnabled(ctx, wac, def)
	g.Expect(err).NotTo(HaveOccurred())
	dep := &appsv1.Deployment{}
	depKey := types.NamespacedName{Namespace: ns, Name: "node-healthcheck-controller-manager"}
	g.Expect(c.Get(ctx, depKey, dep)).To(Succeed())
	dep.Status.ObservedGeneration = dep.Generation
	dep.Status.Replicas = *dep.Spec.Replicas
	dep.Status.ReadyReplicas = *dep.Spec.Replicas
	dep.Status.UpdatedReplicas = *dep.Spec.Replicas
	g.Expect(c.Status().Update(ctx, dep)).To(Succeed())
	generation := dep.Generation
	template := dep.Spec.Template.DeepCopy()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	g.Expect(err).NotTo(HaveOccurred())
	ca, err := cert.NewSelfSignedCACert(cert.Config{CommonName: "envtest"}, key)
	g.Expect(err).NotTo(HaveOccurred())
	hook := &admissionregistrationv1.ValidatingWebhookConfiguration{}
	g.Expect(c.Get(ctx, types.NamespacedName{Name: "node-healthcheck-validating-webhook-configuration"}, hook)).To(Succeed())
	for i := range hook.Webhooks {
		hook.Webhooks[i].ClientConfig.CABundle = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca.Raw})
	}
	g.Expect(c.Update(ctx, hook)).To(Succeed())
	// This manager has its own API server but shares the test process with the
	// Ginkgo manager. Controller-runtime's name registry is process-global.
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{Scheme: s, Metrics: metricsserver.Options{BindAddress: "0"},
		Controller: config.Controller{SkipNameValidation: ptr.To(true)}})
	g.Expect(err).NotTo(HaveOccurred())
	r.Client = mgr.GetClient()
	g.Expect(r.SetupWithManager(mgr)).To(Succeed())
	stopped := make(chan error, 1)
	go func() { stopped <- mgr.Start(ctx) }()
	t.Cleanup(func() { cancel(); g.Expect(<-stopped).To(Succeed()) })
	g.Eventually(func(g Gomega) {
		current := &v1alpha1.WorkloadAvailabilityConfig{}
		g.Expect(c.Get(ctx, types.NamespacedName{Name: wac.Name}, current)).To(Succeed())
		g.Expect(meta.IsStatusConditionTrue(current.Status.Conditions, v1alpha1.ConditionAvailable)).To(BeTrue())
	}, 10*time.Second, 100*time.Millisecond).Should(Succeed())
	// Drain initial owned-resource events before testing deletion recovery.
	g.Eventually(func(g Gomega) {
		current := &v1alpha1.WorkloadAvailabilityConfig{}
		g.Expect(c.Get(ctx, types.NamespacedName{Name: wac.Name}, current)).To(Succeed())
		rv := current.ResourceVersion
		g.Consistently(func() string {
			_ = c.Get(ctx, types.NamespacedName{Name: wac.Name}, current)
			return current.ResourceVersion
		}, time.Second, 100*time.Millisecond).Should(Equal(rv))
	}, 5*time.Second, 100*time.Millisecond).Should(Succeed())
	cmKey := types.NamespacedName{Namespace: ns, Name: "node-healthcheck-ca-bundle"}
	cm := &corev1.ConfigMap{}
	g.Expect(c.Get(ctx, cmKey, cm)).To(Succeed())
	uid := cm.UID
	g.Expect(c.Delete(ctx, cm)).To(Succeed())
	g.Eventually(func(g Gomega) {
		recreated := &corev1.ConfigMap{}
		g.Expect(c.Get(ctx, cmKey, recreated)).To(Succeed())
		g.Expect(recreated.UID).NotTo(Equal(uid))
		g.Expect(recreated.OwnerReferences).To(Equal(cm.OwnerReferences))
	}, 10*time.Second, 100*time.Millisecond).Should(Succeed())
	g.Expect(c.Get(ctx, depKey, dep)).To(Succeed())
	g.Expect(dep.Generation).To(Equal(generation))
	g.Expect(dep.Spec.Template).To(Equal(*template))
}
