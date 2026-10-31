package operands_test

import (
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/medik8s/workload-availability-operator/internal/components"
	"github.com/medik8s/workload-availability-operator/internal/operands"
)

func TestGateCoversEachComponentsOwnAPIGroupOnly(t *testing.T) {
	owner := map[string]string{}
	for _, def := range components.All() {
		objs, err := operands.Gate(def, testNamespace)
		if err != nil {
			t.Fatalf("%s: %v", def.Key, err)
		}
		policy := find(t, objs, "ValidatingAdmissionPolicy", operands.GateName(def))
		binding := find(t, objs, "ValidatingAdmissionPolicyBinding", operands.GateName(def))
		for _, o := range objs {
			if o.GetLabels()[operands.LabelManagedBy] != operands.ManagedByValue || o.GetLabels()[operands.LabelComponent] != def.Key {
				t.Errorf("%s %s: labels %v", def.Key, o.GetKind(), o.GetLabels())
			}
		}
		if got, _, _ := unstructured.NestedString(binding.Object, "spec", "policyName"); got != policy.GetName() {
			t.Errorf("%s: binding policyName %q", def.Key, got)
		}
		if got, _, _ := unstructured.NestedString(policy.Object, "spec", "failurePolicy"); got != "Fail" {
			t.Errorf("%s: failurePolicy %q", def.Key, got)
		}
		rules, _, _ := unstructured.NestedSlice(policy.Object, "spec", "matchConstraints", "resourceRules")
		if len(rules) != 1 {
			t.Fatalf("%s: %d resource rules", def.Key, len(rules))
		}
		groups, _, _ := unstructured.NestedStringSlice(rules[0].(map[string]any), "apiGroups")
		if len(groups) == 0 {
			t.Errorf("%s: no API groups", def.Key)
		}
		for _, g := range groups {
			if prev, dup := owner[g]; dup {
				t.Errorf("API group %s gated by both %s and %s", g, prev, def.Key)
			}
			owner[g] = def.Key
		}
		conds, _, _ := unstructured.NestedSlice(policy.Object, "spec", "matchConditions")
		if len(conds) != 1 || !strings.Contains(conds[0].(map[string]any)["expression"].(string), "system:serviceaccount:"+testNamespace+":") {
			t.Errorf("%s: matchConditions %v do not exempt the install namespace", def.Key, conds)
		}
	}
}
