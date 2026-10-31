package v1alpha1

import (
	"encoding/json"
	"fmt"
	"testing"

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

func TestManagerResourcesOf(t *testing.T) {
	for _, key := range AllComponentKeys {
		t.Run(key, func(t *testing.T) {
			var spec WorkloadAvailabilityConfigSpec
			input := fmt.Sprintf(`{"components":{%q:{"manager":{"resources":{"requests":{"cpu":"100m","memory":"64Mi"}}}}}}`, key)
			if err := json.Unmarshal([]byte(input), &spec); err != nil {
				t.Fatal(err)
			}
			got := spec.ManagerResourcesOf(key)
			if got == nil || got.Requests.Cpu().Cmp(resource.MustParse("100m")) != 0 {
				t.Fatalf("manager resources = %v", got)
			}
			got.Requests[corev1.ResourceCPU] = resource.MustParse("200m")
			delete(got.Requests, corev1.ResourceMemory)
			again := spec.ManagerResourcesOf(key)
			if again.Requests.Cpu().Cmp(resource.MustParse("100m")) != 0 || again.Requests.Memory().Cmp(resource.MustParse("64Mi")) != 0 {
				t.Fatalf("accessor changed stored resources: %v", again)
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
			if got := spec.ManagerResourcesOf(key); got != nil {
				t.Fatalf("%s omitted resources = %v", key, got)
			}
		}
	}
	var spec WorkloadAvailabilityConfigSpec
	if got := spec.ManagerResourcesOf("unknown"); got != nil {
		t.Fatalf("unknown component resources = %v", got)
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
		var got ComponentSpec
		if err := json.Unmarshal(data, &got); err != nil {
			t.Fatal(err)
		}
		if got.Manager == nil || got.Manager.Resources == nil {
			t.Fatalf("round trip lost empty resources: %s", data)
		}
		for _, maps := range []struct{ before, after corev1.ResourceList }{
			{original.Manager.Resources.Requests, got.Manager.Resources.Requests},
			{original.Manager.Resources.Limits, got.Manager.Resources.Limits},
		} {
			if len(maps.before) != len(maps.after) {
				t.Fatalf("round trip lost resource entries: %s", data)
			}
			for name, before := range maps.before {
				after, exists := maps.after[name]
				if !exists || before.Cmp(after) != 0 {
					t.Fatalf("round trip changed %s: %s", name, data)
				}
			}
		}
	}
}
