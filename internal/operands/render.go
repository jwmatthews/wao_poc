package operands

import (
	"fmt"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/yaml"

	"github.com/jwmatthews/wao_poc/internal/components"
	"github.com/jwmatthews/wao_poc/internal/images"
)

const (
	NamespacePlaceholder = "__WAO_NAMESPACE__"
	LabelManagedBy       = "app.kubernetes.io/managed-by"
	ManagedByValue       = "workload-availability-operator"
	LabelComponent       = "workloadavailability.medik8s.io/component"
)

var namespacedKinds = map[string]bool{"Deployment": true, "Service": true, "ConfigMap": true, "Role": true,
	"RoleBinding": true, "ServiceAccount": true, "Secret": true}

var kindOrder = map[string]int{"ServiceAccount": 0, "ClusterRole": 10, "ClusterRoleBinding": 11, "Role": 20,
	"RoleBinding": 21, "ConfigMap": 30, "Service": 40, "Deployment": 50,
	"ValidatingWebhookConfiguration": 60, "MutatingWebhookConfiguration": 61}

// IsNamespaced reports whether a rendered kind lives in the install namespace.
func IsNamespaced(kind string) bool { return namespacedKinds[kind] }

// Render produces the component's objects for one install namespace and image set,
// sorted so that RBAC precedes workloads and admission configurations come last.
func Render(def components.Definition, namespace string, imgs images.Set) ([]*unstructured.Unstructured, error) {
	files, err := Load(def.ManifestDir)
	if err != nil {
		return nil, err
	}
	var out []*unstructured.Unstructured
	for _, name := range sortedNames(files) {
		text := strings.ReplaceAll(string(files[name]), NamespacePlaceholder, namespace)
		for _, b := range def.Images {
			img := imgs.Get(b.Env)
			if img == "" {
				return nil, fmt.Errorf("%s: no image configured for %s", def.Key, b.Env)
			}
			text = strings.ReplaceAll(text, b.Original, img)
		}
		if strings.Contains(text, NamespacePlaceholder) {
			return nil, fmt.Errorf("%s/%s: unresolved namespace placeholder", def.Key, name)
		}
		j, err := yaml.YAMLToJSON([]byte(text))
		if err != nil {
			return nil, fmt.Errorf("%s/%s: %w", def.Key, name, err)
		}
		u := &unstructured.Unstructured{}
		if err := u.UnmarshalJSON(j); err != nil {
			return nil, fmt.Errorf("%s/%s: %w", def.Key, name, err)
		}
		if _, known := kindOrder[u.GetKind()]; !known {
			return nil, fmt.Errorf("%s/%s: unsupported kind %s", def.Key, name, u.GetKind())
		}
		if IsNamespaced(u.GetKind()) && u.GetNamespace() != namespace {
			return nil, fmt.Errorf("%s/%s: namespace %q, want %q", def.Key, name, u.GetNamespace(), namespace)
		}
		labels := u.GetLabels()
		if labels == nil {
			labels = map[string]string{}
		}
		labels[LabelManagedBy] = ManagedByValue
		labels[LabelComponent] = def.Key
		u.SetLabels(labels)
		out = append(out, u)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if kindOrder[out[i].GetKind()] != kindOrder[out[j].GetKind()] {
			return kindOrder[out[i].GetKind()] < kindOrder[out[j].GetKind()]
		}
		return out[i].GetName() < out[j].GetName()
	})
	return out, nil
}
