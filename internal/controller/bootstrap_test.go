package controller

import (
	"context"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
)

func TestEnsureDefaultConfigCreatesDisabledSingleton(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = v1alpha1.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	if err := EnsureDefaultConfig(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	w := &v1alpha1.WorkloadAvailabilityConfig{}
	if err := c.Get(context.Background(), types.NamespacedName{Name: v1alpha1.SingletonName}, w); err != nil {
		t.Fatal(err)
	}
	for _, k := range v1alpha1.AllComponentKeys {
		if w.Spec.StateOf(k) != v1alpha1.ComponentStateDisabled {
			t.Fatalf("%s not Disabled", k)
		}
	}
}

func TestEnsureDefaultConfigLeavesExistingUntouched(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = v1alpha1.AddToScheme(scheme)
	existing := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName}}
	existing.Spec.Components.NodeHealthCheck.State = v1alpha1.ComponentStateEnabled
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(existing).Build()
	if err := EnsureDefaultConfig(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	w := &v1alpha1.WorkloadAvailabilityConfig{}
	_ = c.Get(context.Background(), types.NamespacedName{Name: v1alpha1.SingletonName}, w)
	if w.Spec.StateOf(v1alpha1.ComponentKeyNodeHealthCheck) != v1alpha1.ComponentStateEnabled {
		t.Fatal("existing spec was modified")
	}
}
