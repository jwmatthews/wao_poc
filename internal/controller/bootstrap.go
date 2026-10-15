package controller

import (
	"context"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
)

// EnsureDefaultConfig creates the all-Disabled singleton when it does not exist (D4).
// It never modifies an existing object.
func EnsureDefaultConfig(ctx context.Context, c client.Client) error {
	w := &v1alpha1.WorkloadAvailabilityConfig{ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName}}
	err := c.Create(ctx, w)
	if apierrors.IsAlreadyExists(err) {
		return nil
	}
	return err
}
