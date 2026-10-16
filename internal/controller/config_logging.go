package controller

import (
	"context"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
)

const conflictDiagnosticTimeout = 2 * time.Second

// writeConfig observes one existing write attempt without changing its retry or
// error behavior. Capture attempted metadata before the client replaces it with
// the successful API response.
func (r *WorkloadAvailabilityConfigReconciler) writeConfig(ctx context.Context, wac *v1alpha1.WorkloadAvailabilityConfig, operation string, started time.Time, write func() error, fields ...any) error {
	attemptedUID := wac.UID
	log := logf.FromContext(ctx).WithValues("operation", operation,
		"attemptedResourceVersion", wac.ResourceVersion, "generation", wac.Generation,
		"observedGeneration", wac.Status.ObservedGeneration, "deleting", !wac.DeletionTimestamp.IsZero()).WithValues(fields...)
	log.V(1).Info("writing WorkloadAvailabilityConfig", "reconcileDuration", time.Since(started).String())
	writeStarted := time.Now()
	err := write()
	if err == nil {
		log.V(1).Info("wrote WorkloadAvailabilityConfig", "returnedResourceVersion", wac.ResourceVersion,
			"writeDuration", time.Since(writeStarted).String(), "reconcileDuration", time.Since(started).String())
		return nil
	}

	conflict := apierrors.IsConflict(err)
	// The original error is returned below and logged at Error by controller-runtime.
	// This contextual record avoids a second error stack trace for the same failure.
	log.Info("WorkloadAvailabilityConfig write failed", "error", err.Error(), "conflict", conflict,
		"writeDuration", time.Since(writeStarted).String(), "reconcileDuration", time.Since(started).String())
	if !conflict {
		return err
	}
	if r.APIReader == nil {
		log.Info("WorkloadAvailabilityConfig conflict comparison", "liveReadSucceeded", false,
			"liveReadError", "direct API reader is not configured")
		return err
	}

	// A cached Get would repeat the suspected stale read. A short, direct read is
	// diagnostic only: do not retry the write or replace the original conflict.
	readCtx, cancel := context.WithTimeout(ctx, conflictDiagnosticTimeout)
	defer cancel()
	live := &v1alpha1.WorkloadAvailabilityConfig{}
	readStarted := time.Now()
	if readErr := r.APIReader.Get(readCtx, client.ObjectKeyFromObject(wac), live); readErr != nil {
		log.Info("WorkloadAvailabilityConfig conflict comparison", "liveReadSucceeded", false,
			"liveReadError", readErr.Error(), "liveReadDuration", time.Since(readStarted).String())
		return err
	}
	log.Info("WorkloadAvailabilityConfig conflict comparison", "liveReadSucceeded", true,
		"liveResourceVersion", live.ResourceVersion, "liveGeneration", live.Generation,
		"liveObservedGeneration", live.Status.ObservedGeneration, "liveDeleting", !live.DeletionTimestamp.IsZero(),
		"sameUID", live.UID == attemptedUID, "liveReadDuration", time.Since(readStarted).String())
	return err
}

// logConfigStatus emits a bounded summary after a successful status write, only
// when the computed status differs from the configuration snapshot we read.
func logConfigStatus(ctx context.Context, wac *v1alpha1.WorkloadAvailabilityConfig) {
	phases := make(map[string]v1alpha1.ComponentPhase, len(wac.Status.Components))
	for _, component := range wac.Status.Components {
		phases[component.Name] = component.Phase
	}
	conditions := make(map[string]metav1.ConditionStatus, len(wac.Status.Conditions))
	for _, condition := range wac.Status.Conditions {
		conditions[condition.Type] = condition.Status
	}
	logf.FromContext(ctx).Info("WorkloadAvailabilityConfig status changed", "operation", "status.update",
		"resourceVersion", wac.ResourceVersion, "generation", wac.Generation, "observedGeneration", wac.Status.ObservedGeneration,
		"componentPhases", phases, "conditions", conditions)
}
