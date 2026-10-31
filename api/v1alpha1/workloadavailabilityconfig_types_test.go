package v1alpha1

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

func TestStateOfBooleanInput(t *testing.T) {
	for _, key := range AllComponentKeys {
		for _, tc := range []struct {
			name, input string
			want        ComponentState
		}{
			{"true", `{"enabled":true}`, ComponentStateEnabled},
			{"false", `{"enabled":false}`, ComponentStateDisabled},
			{"omitted", `{}`, ComponentStateDisabled},
		} {
			t.Run(key+"/"+tc.name, func(t *testing.T) {
				var spec WorkloadAvailabilityConfigSpec
				if err := json.Unmarshal([]byte(fmt.Sprintf(`{"components":{%q:%s}}`, key, tc.input)), &spec); err != nil {
					t.Fatal(err)
				}
				if got := spec.StateOf(key); got != tc.want {
					t.Fatalf("StateOf(%q) = %q, want %q", key, got, tc.want)
				}
				for _, other := range AllComponentKeys {
					if other != key && spec.StateOf(other) != ComponentStateDisabled {
						t.Errorf("configuring %s enabled %s", key, other)
					}
				}
			})
		}
	}
	var spec WorkloadAvailabilityConfigSpec
	if got := spec.StateOf("unknown"); got != ComponentStateDisabled {
		t.Fatalf("unknown component state = %q", got)
	}
}

func TestComponentJSONPreservesFalse(t *testing.T) {
	for _, tc := range []struct {
		component ComponentSpec
		want      string
	}{
		{ComponentSpec{}, `{"enabled":false}`},
		{ComponentSpec{Enabled: true}, `{"enabled":true}`},
	} {
		data, err := json.Marshal(tc.component)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != tc.want {
			t.Fatalf("component JSON = %s, want %s", data, tc.want)
		}
	}
}

func TestQuantityAcceptsJSONIntegersAndStrings(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{`{"cpu":1}`, "1"},
		{`{"cpu":0}`, "0"},
		{`{"cpu":"500m"}`, "500m"},
		{`{"cpu":"256Mi"}`, "256Mi"},
		{`{"cpu":"1"}`, "1"},
	} {
		var got CPUMemory
		if err := json.Unmarshal([]byte(tc.input), &got); err != nil {
			t.Fatalf("%s: %v", tc.input, err)
		}
		if got.CPU == nil || string(*got.CPU) != tc.want {
			t.Fatalf("%s decoded to %v, want %s", tc.input, got.CPU, tc.want)
		}
	}
	var got CPUMemory
	if err := json.Unmarshal([]byte(`{"cpu":true}`), &got); err == nil {
		t.Fatalf("boolean quantity decoded to %v", got.CPU)
	}
}

func TestManagerResourcesOf(t *testing.T) {
	for _, key := range AllComponentKeys {
		t.Run(key, func(t *testing.T) {
			var spec WorkloadAvailabilityConfigSpec
			input := fmt.Sprintf(`{"components":{%q:{"manager":{"resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":1}}}}}}`, key)
			if err := json.Unmarshal([]byte(input), &spec); err != nil {
				t.Fatal(err)
			}
			got, err := spec.ManagerResourcesOf(key)
			if err != nil {
				t.Fatal(err)
			}
			if got == nil || got.Requests.Cpu().Cmp(resource.MustParse("100m")) != 0 ||
				got.Requests.Memory().Cmp(resource.MustParse("64Mi")) != 0 ||
				got.Limits.Cpu().Cmp(resource.MustParse("1")) != 0 {
				t.Fatalf("manager resources = %v", got)
			}
			if _, set := got.Limits[corev1.ResourceMemory]; set {
				t.Fatalf("omitted memory limit was set: %v", got.Limits)
			}
			got.Requests[corev1.ResourceCPU] = resource.MustParse("200m")
			again, err := spec.ManagerResourcesOf(key)
			if err != nil || again.Requests.Cpu().Cmp(resource.MustParse("100m")) != 0 {
				t.Fatalf("accessor changed stored resources: %v (%v)", again, err)
			}
			if spec.StateOf(key) != ComponentStateDisabled {
				t.Fatal("manager resources enabled the component")
			}
		})
	}
}

func TestManagerResourcesOfOmitted(t *testing.T) {
	for _, input := range []string{`{}`, `{"manager":{}}`} {
		for _, key := range AllComponentKeys {
			var spec WorkloadAvailabilityConfigSpec
			if err := json.Unmarshal([]byte(fmt.Sprintf(`{"components":{%q:%s}}`, key, input)), &spec); err != nil {
				t.Fatal(err)
			}
			if got, err := spec.ManagerResourcesOf(key); got != nil || err != nil {
				t.Fatalf("%s omitted resources = %v (%v)", key, got, err)
			}
		}
	}
	var spec WorkloadAvailabilityConfigSpec
	if got, err := spec.ManagerResourcesOf("unknown"); got != nil || err != nil {
		t.Fatalf("unknown component resources = %v (%v)", got, err)
	}
}

func TestManagerResourcesOfEmptyMaps(t *testing.T) {
	var spec WorkloadAvailabilityConfigSpec
	input := `{"components":{"nodeHealthCheck":{"manager":{"resources":{"requests":{},"limits":{}}}}}}`
	if err := json.Unmarshal([]byte(input), &spec); err != nil {
		t.Fatal(err)
	}
	got, err := spec.ManagerResourcesOf(ComponentKeyNodeHealthCheck)
	if err != nil || got == nil || len(got.Requests) != 0 || len(got.Limits) != 0 {
		t.Fatalf("empty resources = %v (%v)", got, err)
	}
}

// Admission rejects these values. The accessor repeats the check for objects stored
// before the CEL rule existed, and must return before ParseQuantity can stall.
func TestManagerResourcesOfRejectsInvalidQuantities(t *testing.T) {
	for _, value := range []string{"bogus", "1e1.5", "1e1000", "1e2147483648", "1e-2147483649", "1e9223372036854775807"} {
		t.Run(value, func(t *testing.T) {
			var spec WorkloadAvailabilityConfigSpec
			input := fmt.Sprintf(`{"components":{"nodeHealthCheck":{"manager":{"resources":{"limits":{"memory":%q}}}}}}`, value)
			if err := json.Unmarshal([]byte(input), &spec); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() {
				_, err := spec.ManagerResourcesOf(ComponentKeyNodeHealthCheck)
				done <- err
			}()
			select {
			case err := <-done:
				if err == nil || !strings.Contains(err.Error(), "limits.memory") || !strings.Contains(err.Error(), value) {
					t.Fatalf("error = %v, want limits.memory and %q", err, value)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("quantity check did not return")
			}
		})
	}
}

func TestComponentResourcesJSONRoundTrip(t *testing.T) {
	for _, input := range []string{
		`{"enabled":false,"manager":{"resources":{}}}`,
		`{"enabled":false,"manager":{"resources":{"requests":{},"limits":{}}}}`,
		`{"enabled":false,"manager":{"resources":{"requests":{"cpu":"0"},"limits":{"memory":"0"}}}}`,
	} {
		var original ComponentSpec
		if err := json.Unmarshal([]byte(input), &original); err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(original)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != input {
			t.Fatalf("round trip = %s, want %s", data, input)
		}
	}
}
