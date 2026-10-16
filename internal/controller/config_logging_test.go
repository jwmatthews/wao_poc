package controller

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
)

func TestConfigWriteDiagnostics(t *testing.T) {
	conflict := apierrors.NewConflict(schema.GroupResource{Group: v1alpha1.GroupVersion.Group, Resource: "workloadavailabilityconfigs"}, v1alpha1.SingletonName, errors.New("version changed"))
	forbidden := apierrors.NewForbidden(schema.GroupResource{Resource: "workloadavailabilityconfigs"}, v1alpha1.SingletonName, errors.New("denied"))
	for _, tc := range []struct {
		name      string
		operation string
		writeErr  error
		readErr   error
	}{
		{name: "status success", operation: "status.update"},
		{name: "status conflict", operation: "status.update", writeErr: conflict},
		{name: "diagnostic failure preserves conflict", operation: "status.update", writeErr: conflict, readErr: errors.New("diagnostic read unavailable")},
		{name: "non-conflict skips diagnostic read", operation: "status.update", writeErr: forbidden},
		{name: "finalizer addition conflict", operation: "finalizer.add", writeErr: conflict},
		{name: "finalizer removal conflict", operation: "finalizer.remove", writeErr: conflict},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cached := loggingTestConfig()
			if tc.operation == "finalizer.add" {
				cached.Finalizers = nil
			}
			if tc.operation == "finalizer.remove" {
				now := metav1.Now()
				cached.DeletionTimestamp = &now
			}
			writes := 0
			c := loggingTestClient(t, cached, func(obj client.Object) error {
				writes++
				if tc.writeErr == nil {
					// Like the real client, a successful update replaces metadata on obj.
					obj.SetResourceVersion("returned-version")
				}
				return tc.writeErr
			})
			liveReads := 0
			live := cached.DeepCopy()
			live.ResourceVersion, live.Generation = "live-version", 3
			live.Status.ObservedGeneration = 2
			live.DeletionTimestamp = &metav1.Time{Time: time.Now()}
			reader := fake.NewClientBuilder().WithScheme(c.Scheme()).WithInterceptorFuncs(interceptor.Funcs{
				Get: func(ctx context.Context, _ client.WithWatch, _ client.ObjectKey, obj client.Object, _ ...client.GetOption) error {
					liveReads++
					if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > 3*time.Second {
						t.Error("diagnostic read must have a short timeout")
					}
					if tc.readErr != nil {
						return tc.readErr
					}
					*obj.(*v1alpha1.WorkloadAvailabilityConfig) = *live.DeepCopy()
					return nil
				},
			}).Build()
			r := &WorkloadAvailabilityConfigReconciler{Client: c, APIReader: reader, Namespace: ns, Images: testImages()}
			var output bytes.Buffer
			ctx := logf.IntoContext(context.Background(), zap.New(zap.WriteTo(&output), zap.UseDevMode(true), zap.JSONEncoder()).WithValues("reconcileID", "test-reconcile"))
			_, err := r.Reconcile(ctx, reconcile.Request{NamespacedName: client.ObjectKey{Name: v1alpha1.SingletonName}})
			if err != tc.writeErr {
				t.Fatalf("returned error %v, want original write error %v", err, tc.writeErr)
			}
			if writes != 1 {
				t.Fatalf("writes = %d, want one attempt with existing retry behavior", writes)
			}
			entries := decodeConfigLogs(t, &output)
			read := configLogEntry(t, entries, "read WorkloadAvailabilityConfig")
			assertLogFields(t, read, map[string]any{"operation": "config.get", "resourceVersion": "cached-version", "generation": float64(2), "observedGeneration": float64(1), "reconcileID": "test-reconcile"})
			attempt := configLogEntry(t, entries, "writing WorkloadAvailabilityConfig")
			assertLogFields(t, attempt, map[string]any{"operation": tc.operation, "attemptedResourceVersion": "cached-version", "generation": float64(2)})
			if _, ok := attempt["reconcileDuration"]; !ok {
				t.Error("missing reconciliation duration")
			}
			if tc.operation == "status.update" {
				assertLogFields(t, attempt, map[string]any{"statusChanged": true, "observedGeneration": float64(2)})
			}
			if tc.writeErr == nil {
				assertLogFields(t, configLogEntry(t, entries, "wrote WorkloadAvailabilityConfig"), map[string]any{"attemptedResourceVersion": "cached-version", "returnedResourceVersion": "returned-version"})
				summary := configLogEntry(t, entries, "WorkloadAvailabilityConfig status changed")
				assertLogFields(t, summary["conditions"].(map[string]any), map[string]any{"Available": "True", "Progressing": "False", "Degraded": "False"})
				if len(summary["componentPhases"].(map[string]any)) != 6 {
					t.Error("status summary must include all six component phases")
				}
			} else {
				assertLogFields(t, configLogEntry(t, entries, "WorkloadAvailabilityConfig write failed"), map[string]any{"operation": tc.operation, "conflict": apierrors.IsConflict(tc.writeErr), "attemptedResourceVersion": "cached-version"})
			}
			if apierrors.IsConflict(tc.writeErr) {
				if liveReads != 1 {
					t.Fatalf("direct reads = %d, want one after conflict", liveReads)
				}
				comparison := configLogEntry(t, entries, "WorkloadAvailabilityConfig conflict comparison")
				assertLogFields(t, comparison, map[string]any{"operation": tc.operation, "attemptedResourceVersion": "cached-version", "liveReadSucceeded": tc.readErr == nil})
				if tc.readErr == nil {
					assertLogFields(t, comparison, map[string]any{"liveResourceVersion": "live-version", "liveGeneration": float64(3), "liveObservedGeneration": float64(2), "liveDeleting": true, "sameUID": true})
				} else {
					assertLogFields(t, comparison, map[string]any{"liveReadError": tc.readErr.Error()})
				}
			} else if liveReads != 0 {
				t.Fatalf("unexpected direct diagnostic reads: %d", liveReads)
			}
		})
	}
}

func TestConfigStatusSummaryOnlyWhenChanged(t *testing.T) {
	cached := loggingTestConfig()
	writes := 0
	c := loggingTestClient(t, cached, func(obj client.Object) error {
		writes++
		*cached = *obj.(*v1alpha1.WorkloadAvailabilityConfig).DeepCopy()
		return nil
	})
	r := &WorkloadAvailabilityConfigReconciler{Client: c, Namespace: ns, Images: testImages()}
	var output bytes.Buffer
	ctx := logf.IntoContext(context.Background(), zap.New(zap.WriteTo(&output), zap.UseDevMode(true), zap.JSONEncoder()))
	for range 2 {
		if _, err := r.Reconcile(ctx, reconcile.Request{NamespacedName: client.ObjectKey{Name: v1alpha1.SingletonName}}); err != nil {
			t.Fatal(err)
		}
	}
	if writes != 2 {
		t.Fatalf("logging changed write behavior: got %d status attempts, want 2", writes)
	}
	entries := decodeConfigLogs(t, &output)
	summaries, unchanged := 0, 0
	for _, entry := range entries {
		if entry["msg"] == "WorkloadAvailabilityConfig status changed" {
			summaries++
		}
		if entry["msg"] == "writing WorkloadAvailabilityConfig" && entry["statusChanged"] == false {
			unchanged++
		}
	}
	if summaries != 1 || unchanged != 1 {
		t.Fatalf("summaries=%d unchanged attempts=%d, want one of each", summaries, unchanged)
	}
}

func loggingTestConfig() *v1alpha1.WorkloadAvailabilityConfig {
	return &v1alpha1.WorkloadAvailabilityConfig{
		ObjectMeta: metav1.ObjectMeta{Name: v1alpha1.SingletonName, UID: "test-config", ResourceVersion: "cached-version", Generation: 2, Finalizers: []string{Finalizer}},
		Status:     v1alpha1.WorkloadAvailabilityConfigStatus{ObservedGeneration: 1},
	}
}

func loggingTestClient(t *testing.T, cached *v1alpha1.WorkloadAvailabilityConfig, write func(client.Object) error) client.Client {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := v1alpha1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	return fake.NewClientBuilder().WithScheme(scheme).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(_ context.Context, _ client.WithWatch, key client.ObjectKey, obj client.Object, _ ...client.GetOption) error {
			if wac, ok := obj.(*v1alpha1.WorkloadAvailabilityConfig); ok {
				*wac = *cached.DeepCopy()
				return nil
			}
			return apierrors.NewNotFound(schema.GroupResource{Resource: "operand"}, key.Name)
		},
		List: func(context.Context, client.WithWatch, client.ObjectList, ...client.ListOption) error { return nil },
		Update: func(_ context.Context, _ client.WithWatch, obj client.Object, _ ...client.UpdateOption) error {
			return write(obj)
		},
		SubResourceUpdate: func(_ context.Context, _ client.Client, _ string, obj client.Object, _ ...client.SubResourceUpdateOption) error {
			return write(obj)
		},
	}).Build()
}

func decodeConfigLogs(t *testing.T, output *bytes.Buffer) []map[string]any {
	t.Helper()
	var entries []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(output.String()), "\n") {
		if line == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("invalid structured log: %v: %s", err, line)
		}
		entries = append(entries, entry)
	}
	return entries
}

func configLogEntry(t *testing.T, entries []map[string]any, message string) map[string]any {
	t.Helper()
	for _, entry := range entries {
		if entry["msg"] == message {
			return entry
		}
	}
	t.Fatalf("missing log %q; entries: %+v", message, entries)
	return nil
}

func assertLogFields(t *testing.T, entry, expected map[string]any) {
	t.Helper()
	for key, value := range expected {
		if entry[key] != value {
			t.Errorf("%s = %v, want %v", key, entry[key], value)
		}
	}
}
