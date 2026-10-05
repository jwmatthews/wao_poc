package v1alpha1

import "testing"

func TestStateOfDefaultsToDisabled(t *testing.T) {
	spec := &WorkloadAvailabilityConfigSpec{}
	for _, key := range AllComponentKeys {
		if got := spec.StateOf(key); got != ComponentStateDisabled {
			t.Fatalf("StateOf(%q) = %q, want Disabled", key, got)
		}
	}
}

func TestStateOfReturnsConfiguredState(t *testing.T) {
	spec := &WorkloadAvailabilityConfigSpec{}
	spec.Components.SelfNodeRemediation.State = ComponentStateEnabled
	if got := spec.StateOf(ComponentKeySelfNodeRemediation); got != ComponentStateEnabled {
		t.Fatalf("got %q, want Enabled", got)
	}
	if got := spec.StateOf(ComponentKeyNodeHealthCheck); got != ComponentStateDisabled {
		t.Fatalf("got %q, want Disabled", got)
	}
}

func TestStateOfUnknownKeyIsDisabled(t *testing.T) {
	spec := &WorkloadAvailabilityConfigSpec{}
	if got := spec.StateOf("bogus"); got != ComponentStateDisabled {
		t.Fatalf("got %q, want Disabled", got)
	}
}
