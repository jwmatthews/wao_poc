package operands

import (
	"fmt"
	"sort"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"

	"github.com/medik8s/workload-availability-operator/internal/components"
)

// ApplyManagerResources merges overrides into the named manager's packaged resources.
// A nil override leaves every object unchanged. Validation errors also leave objects unchanged.
func ApplyManagerResources(def components.Definition, objects []*unstructured.Unstructured, overrides *corev1.ResourceRequirements) error {
	if overrides == nil {
		return nil
	}
	path := "spec.components." + def.Key + ".manager.resources"
	target := fmt.Sprintf("Deployment/%s container/%s", def.ManagerDeployment, def.ManagerContainer)
	targetError := func(err error) error { return fmt.Errorf("%s: %s: %w", path, target, err) }
	if def.ManagerDeployment == "" || def.ManagerContainer == "" {
		return targetError(fmt.Errorf("manager Deployment and container names must be declared"))
	}
	var deployment *unstructured.Unstructured
	deployments := 0
	for _, object := range objects {
		if object.GetKind() == "Deployment" && object.GetName() == def.ManagerDeployment {
			deployment = object
			deployments++
		}
	}
	if deployments != 1 {
		return targetError(fmt.Errorf("found %d matching Deployments, want exactly one", deployments))
	}
	containersPath := []string{"spec", "template", "spec", "containers"}
	containers, _, err := unstructured.NestedSlice(deployment.Object, containersPath...)
	if err != nil {
		return targetError(err)
	}
	var manager map[string]any
	matches := 0
	for _, raw := range containers {
		container, ok := raw.(map[string]any)
		if !ok {
			return targetError(fmt.Errorf("containers entry must be an object"))
		}
		name, _, err := unstructured.NestedString(container, "name")
		if err != nil {
			return targetError(err)
		}
		if name == def.ManagerContainer {
			manager = container
			matches++
		}
	}
	if matches != 1 {
		return targetError(fmt.Errorf("found %d matching containers, want exactly one", matches))
	}
	resources, _, err := unstructured.NestedMap(manager, "resources")
	if err != nil {
		return targetError(err)
	}
	var defaults corev1.ResourceRequirements
	if resources != nil {
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(resources, &defaults); err != nil {
			return targetError(fmt.Errorf("read packaged resources: %w", err))
		}
	}
	effective, err := mergeResources(defaults, *overrides)
	if err != nil {
		return fmt.Errorf("%s.%w", path, err)
	}
	if len(overrides.Requests) == 0 && len(overrides.Limits) == 0 {
		return nil
	}
	effectiveMap, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&effective)
	if err != nil {
		return targetError(fmt.Errorf("convert effective resources: %w", err))
	}
	// Preserve other resource fields and all container fields from the unstructured object.
	if resources == nil {
		resources = map[string]any{}
	}
	for _, field := range []string{"requests", "limits"} {
		if value, exists := effectiveMap[field]; exists {
			resources[field] = value
		}
	}
	manager["resources"] = resources
	if err := unstructured.SetNestedSlice(deployment.Object, containers, containersPath...); err != nil {
		return targetError(err)
	}
	return nil
}

// mergeResources replaces supplied map entries and checks the effective CPU and memory values.
// Neither input shares mutable resource maps with the result.
func mergeResources(defaults corev1.ResourceRequirements, overrides corev1.ResourceRequirements) (corev1.ResourceRequirements, error) {
	if len(overrides.Claims) != 0 {
		return corev1.ResourceRequirements{}, fmt.Errorf("claims: resource claims are not supported")
	}
	for _, field := range []struct {
		name   string
		values corev1.ResourceList
	}{
		{"requests", overrides.Requests}, {"limits", overrides.Limits},
	} {
		names := make([]string, 0, len(field.values))
		for name := range field.values {
			names = append(names, string(name))
		}
		sort.Strings(names)
		for _, name := range names {
			if name != string(corev1.ResourceCPU) && name != string(corev1.ResourceMemory) {
				return corev1.ResourceRequirements{}, fmt.Errorf("%s.%s: only cpu and memory are supported", field.name, name)
			}
		}
	}
	effective := defaults.DeepCopy()
	if len(overrides.Requests) > 0 && effective.Requests == nil {
		effective.Requests = corev1.ResourceList{}
	}
	for name, quantity := range overrides.Requests {
		effective.Requests[name] = quantity.DeepCopy()
	}
	if len(overrides.Limits) > 0 && effective.Limits == nil {
		effective.Limits = corev1.ResourceList{}
	}
	for name, quantity := range overrides.Limits {
		effective.Limits[name] = quantity.DeepCopy()
	}
	for _, name := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
		for _, field := range []struct {
			name   string
			values corev1.ResourceList
		}{
			{"requests", effective.Requests}, {"limits", effective.Limits},
		} {
			if quantity, exists := field.values[name]; exists && quantity.Sign() < 0 {
				return corev1.ResourceRequirements{}, fmt.Errorf("%s.%s: quantity %s must not be negative", field.name, name, quantity.String())
			}
		}
		request, hasRequest := effective.Requests[name]
		limit, hasLimit := effective.Limits[name]
		if hasRequest && hasLimit && request.Cmp(limit) > 0 {
			return corev1.ResourceRequirements{}, fmt.Errorf("requests.%s: effective request %s exceeds effective limit %s", name, request.String(), limit.String())
		}
	}
	return *effective, nil
}
