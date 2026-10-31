package operands

import (
	"fmt"
	"strings"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/utils/ptr"

	"github.com/medik8s/workload-availability-operator/internal/components"
)

// GateName names the admission gate objects (policy and binding) of a component.
func GateName(def components.Definition) string {
	return "workload-availability-" + def.ShortName + "-gate"
}

// Gate renders an in-tree ValidatingAdmissionPolicy and its binding that deny creating, or
// changing the spec of, the component's native resources while the component is not Available.
// It needs no webhook backend, so it closes the window in which a Disabled or starting component
// would otherwise accept objects that skipped its own admission webhooks. Service accounts in
// the install namespace are exempt: the operand managers and their agents run there and must be
// able to write their own objects during startup. Deletes, metadata-only updates (such as
// removing a finalizer) and status updates stay allowed.
func Gate(def components.Definition, namespace string) ([]*unstructured.Unstructured, error) {
	groups := def.APIGroups()
	if len(groups) == 0 {
		return nil, fmt.Errorf("%s: no API groups to gate", def.Key)
	}
	name := GateName(def)
	labels := map[string]string{LabelManagedBy: ManagedByValue, LabelComponent: def.Key}
	policy := &admissionregistrationv1.ValidatingAdmissionPolicy{
		TypeMeta:   metav1.TypeMeta{APIVersion: admissionregistrationv1.SchemeGroupVersion.String(), Kind: "ValidatingAdmissionPolicy"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels},
		Spec: admissionregistrationv1.ValidatingAdmissionPolicySpec{
			FailurePolicy: ptr.To(admissionregistrationv1.Fail),
			MatchConstraints: &admissionregistrationv1.MatchResources{
				ResourceRules: []admissionregistrationv1.NamedRuleWithOperations{{
					RuleWithOperations: admissionregistrationv1.RuleWithOperations{
						Operations: []admissionregistrationv1.OperationType{admissionregistrationv1.Create, admissionregistrationv1.Update},
						Rule:       admissionregistrationv1.Rule{APIGroups: groups, APIVersions: []string{"*"}, Resources: []string{"*"}},
					},
				}},
			},
			MatchConditions: []admissionregistrationv1.MatchCondition{{
				Name:       "exclude-install-namespace-service-accounts",
				Expression: fmt.Sprintf("!request.userInfo.username.startsWith('system:serviceaccount:%s:')", namespace),
			}},
			Validations: []admissionregistrationv1.Validation{{
				Expression: "request.operation == 'UPDATE' && (has(object.spec) ? has(oldObject.spec) && object.spec == oldObject.spec : !has(oldObject.spec))",
				Message: fmt.Sprintf("%s resources cannot be created or have their spec changed while WorkloadAvailabilityConfig component %s is not Available; enable it and wait for it to become Available",
					strings.Join(groups, ", "), def.Key),
				Reason: ptr.To(metav1.StatusReasonForbidden),
			}},
		},
	}
	binding := &admissionregistrationv1.ValidatingAdmissionPolicyBinding{
		TypeMeta:   metav1.TypeMeta{APIVersion: admissionregistrationv1.SchemeGroupVersion.String(), Kind: "ValidatingAdmissionPolicyBinding"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels},
		Spec: admissionregistrationv1.ValidatingAdmissionPolicyBindingSpec{
			PolicyName:        name,
			ValidationActions: []admissionregistrationv1.ValidationAction{admissionregistrationv1.Deny},
		},
	}
	objs := []runtime.Object{policy, binding}
	out := make([]*unstructured.Unstructured, 0, len(objs))
	for _, o := range objs {
		m, err := runtime.DefaultUnstructuredConverter.ToUnstructured(o)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", def.Key, err)
		}
		u := &unstructured.Unstructured{Object: m}
		unstructured.RemoveNestedField(u.Object, "metadata", "creationTimestamp")
		unstructured.RemoveNestedField(u.Object, "status")
		out = append(out, u)
	}
	return out, nil
}
