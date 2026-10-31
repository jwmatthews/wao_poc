/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1alpha1

import (
	"encoding/json"
	"fmt"
	"regexp"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ComponentState represents the controller's desired state in component status.
// +kubebuilder:validation:Enum=Enabled;Disabled
type ComponentState string

const (
	ComponentStateEnabled  ComponentState = "Enabled"
	ComponentStateDisabled ComponentState = "Disabled"
)

const (
	ComponentKeyNodeHealthCheck            = "nodeHealthCheck"
	ComponentKeySelfNodeRemediation        = "selfNodeRemediation"
	ComponentKeyStorageBasedRemediation    = "storageBasedRemediation"
	ComponentKeyNodeMaintenance            = "nodeMaintenance"
	ComponentKeyFenceAgentsRemediation     = "fenceAgentsRemediation"
	ComponentKeyMachineDeletionRemediation = "machineDeletionRemediation"

	// SingletonName is the only permitted WorkloadAvailabilityConfig name.
	SingletonName = "cluster"
)

// AllComponentKeys lists every component key the API accepts, in display order.
var AllComponentKeys = []string{
	ComponentKeyNodeHealthCheck, ComponentKeySelfNodeRemediation, ComponentKeyStorageBasedRemediation,
	ComponentKeyNodeMaintenance, ComponentKeyFenceAgentsRemediation, ComponentKeyMachineDeletionRemediation,
}

// ComponentSpec configures one component.
type ComponentSpec struct {
	// Enabled runs the operator when true. The default is false.
	// Disabling removes its manager and managed installation resources.
	// Existing agents, configuration, and native resources can remain.
	// Complete active maintenance or remediation before disabling.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Enabled",xDescriptors={"urn:alm:descriptor:com.tectonic.ui:booleanSwitch"},order=1
	// +kubebuilder:default=false
	// +optional
	Enabled bool `json:"enabled"`
	// Manager configures the component's manager container.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Manager",order=2
	// +optional
	Manager *ManagerSpec `json:"manager,omitempty"`
}

// ManagerSpec configures the component's manager container.
type ManagerSpec struct {
	// Resources sets CPU and memory for the manager container only.
	// Omitted values retain the packaged defaults. Settings do not enable the component.
	// WAO checks effective values when the component is enabled.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Manager Resources",order=2
	// +optional
	Resources *ManagerResources `json:"resources,omitempty"`
}

// ManagerResources sets manager CPU and memory requests and limits.
type ManagerResources struct {
	// Requests sets the minimum CPU and memory for the manager container.
	// +optional
	Requests *CPUMemory `json:"requests,omitempty"`
	// Limits sets the maximum CPU and memory for the manager container.
	// +optional
	Limits *CPUMemory `json:"limits,omitempty"`
}

// CPUMemory holds a CPU and a memory quantity.
type CPUMemory struct {
	// CPU is a Kubernetes quantity, for example 100m or 1.
	// +optional
	CPU *Quantity `json:"cpu,omitempty"`
	// Memory is a Kubernetes quantity, for example 128Mi or 1Gi.
	// +optional
	Memory *Quantity `json:"memory,omitempty"`
}

// Quantity is a Kubernetes resource quantity written as a JSON integer or string.
// The schema uses type string without anyOf so the console renders a text field.
// The guard rejects exponents of four or more digits before isQuantity runs,
// because ParseQuantity can stall on very large exponents.
// +kubebuilder:validation:Type=string
// +kubebuilder:validation:Format=int-or-string
// +kubebuilder:validation:XIntOrString
// +kubebuilder:validation:MaxLength=32
// +kubebuilder:validation:XValidation:rule="!string(self).matches('[eE][-+]?[0-9]{4,}') && isQuantity(string(self))",message="must be a Kubernetes quantity such as 500m, 1 or 256Mi, with an exponent of at most three digits"
type Quantity string

// UnmarshalJSON accepts a JSON integer or string. Admission permits both forms.
func (q *Quantity) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*q = Quantity(s)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(data, &n); err != nil {
		return fmt.Errorf("quantity must be a JSON integer or string: %w", err)
	}
	*q = Quantity(n)
	return nil
}

// longExponent matches the exponents the CEL guard rejects.
var longExponent = regexp.MustCompile(`[eE][-+]?[0-9]{4,}`)

// Parse checks the value with the admission rule before calling ParseQuantity.
func (q Quantity) Parse() (resource.Quantity, error) {
	if longExponent.MatchString(string(q)) {
		return resource.Quantity{}, fmt.Errorf("quantity %q has an exponent longer than three digits", string(q))
	}
	parsed, err := resource.ParseQuantity(string(q))
	if err != nil {
		return resource.Quantity{}, fmt.Errorf("quantity %q: %w", string(q), err)
	}
	return parsed, nil
}

// ComponentsSpec holds per-component intent. Every component defaults to Disabled.
type ComponentsSpec struct {
	// Runs the Node Health Check operator. Configure a NodeHealthCheck policy
	// separately to enable automated health monitoring and remediation.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Node Health Check",order=2
	// +optional
	NodeHealthCheck ComponentSpec `json:"nodeHealthCheck,omitempty"`
	// Runs the Self Node Remediation operator. Enabling this component creates
	// its default configuration and starts privileged node agents on eligible
	// nodes. Disabling does not remove existing node agents or their configuration.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Self Node Remediation",order=3
	// +optional
	SelfNodeRemediation ComponentSpec `json:"selfNodeRemediation,omitempty"`
	// Runs the Storage Based Remediation operator. Configure a
	// StorageBasedRemediationConfig separately to deploy its agents and configure
	// storage-based fencing. Existing agents and storage configuration can remain
	// after disabling.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Storage Based Remediation",order=4
	// +optional
	StorageBasedRemediation ComponentSpec `json:"storageBasedRemediation,omitempty"`
	// Runs the Node Maintenance operator. Creating a NodeMaintenance resource
	// separately requests node cordoning and draining. Complete active maintenance
	// before disabling; stopping the manager does not uncordon a node.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Node Maintenance",order=5
	// +optional
	NodeMaintenance ComponentSpec `json:"nodeMaintenance,omitempty"`
	// Runs the Fence Agents Remediation operator. Fencing requires separately
	// configured remediation resources and fence-agent credentials.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Fence Agents Remediation",order=6
	// +optional
	FenceAgentsRemediation ComponentSpec `json:"fenceAgentsRemediation,omitempty"`
	// Runs the Machine Deletion Remediation operator. Machine deletion requires
	// a separate remediation request.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Machine Deletion Remediation",order=7
	// +optional
	MachineDeletionRemediation ComponentSpec `json:"machineDeletionRemediation,omitempty"`
}

// WorkloadAvailabilityConfigSpec defines the desired state of the installation.
type WorkloadAvailabilityConfigSpec struct {
	// Choose which component operators WAO runs. All components default to
	// Disabled. Disabling removes the component manager and its managed
	// installation resources; resources created by that component can remain.
	// Disable a component only when it has no active work.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="Components",order=1
	// +optional
	Components ComponentsSpec `json:"components,omitempty"`
}

// StateOf returns the effective state for a component key.
// Unknown keys and unset entries are Disabled.
func (s *WorkloadAvailabilityConfigSpec) StateOf(key string) ComponentState {
	c, ok := s.componentOf(key)
	if ok && c.Enabled {
		return ComponentStateEnabled
	}
	return ComponentStateDisabled
}

// ManagerResourcesOf converts the configured manager resources to ResourceRequirements.
// Unknown keys and omitted resources return nil. Errors name the field, such as limits.memory.
func (s *WorkloadAvailabilityConfigSpec) ManagerResourcesOf(key string) (*corev1.ResourceRequirements, error) {
	c, ok := s.componentOf(key)
	if !ok || c.Manager == nil || c.Manager.Resources == nil {
		return nil, nil
	}
	out := &corev1.ResourceRequirements{}
	for _, field := range []struct {
		name   string
		values *CPUMemory
		target *corev1.ResourceList
	}{
		{"requests", c.Manager.Resources.Requests, &out.Requests},
		{"limits", c.Manager.Resources.Limits, &out.Limits},
	} {
		if field.values == nil {
			continue
		}
		*field.target = corev1.ResourceList{}
		for _, entry := range []struct {
			name  corev1.ResourceName
			value *Quantity
		}{
			{corev1.ResourceCPU, field.values.CPU}, {corev1.ResourceMemory, field.values.Memory},
		} {
			if entry.value == nil {
				continue
			}
			parsed, err := entry.value.Parse()
			if err != nil {
				return nil, fmt.Errorf("%s.%s: %w", field.name, entry.name, err)
			}
			(*field.target)[entry.name] = parsed
		}
	}
	return out, nil
}

func (s *WorkloadAvailabilityConfigSpec) componentOf(key string) (ComponentSpec, bool) {
	switch key {
	case ComponentKeyNodeHealthCheck:
		return s.Components.NodeHealthCheck, true
	case ComponentKeySelfNodeRemediation:
		return s.Components.SelfNodeRemediation, true
	case ComponentKeyStorageBasedRemediation:
		return s.Components.StorageBasedRemediation, true
	case ComponentKeyNodeMaintenance:
		return s.Components.NodeMaintenance, true
	case ComponentKeyFenceAgentsRemediation:
		return s.Components.FenceAgentsRemediation, true
	case ComponentKeyMachineDeletionRemediation:
		return s.Components.MachineDeletionRemediation, true
	default:
		return ComponentSpec{}, false
	}
}

// ComponentPhase summarizes one component's observed lifecycle state.
type ComponentPhase string

const (
	ComponentPhaseDisabled          ComponentPhase = "Disabled"
	ComponentPhaseProgressing       ComponentPhase = "Progressing"
	ComponentPhaseAvailable         ComponentPhase = "Available"
	ComponentPhaseDegraded          ComponentPhase = "Degraded"
	ComponentPhaseDisableIncomplete ComponentPhase = "DisableIncomplete"
)

const (
	ConditionAvailable   = "Available"
	ConditionProgressing = "Progressing"
	ConditionDegraded    = "Degraded"
)

// DeploymentStatus reports one operand Deployment.
type DeploymentStatus struct {
	Name            string `json:"name"`
	Ready           bool   `json:"ready"`
	ReadyReplicas   int32  `json:"readyReplicas"`
	DesiredReplicas int32  `json:"desiredReplicas"`
}

// ComponentStatus reports one component.
type ComponentStatus struct {
	Name         string         `json:"name"`
	DesiredState ComponentState `json:"desiredState"`
	Phase        ComponentPhase `json:"phase"`
	// +optional
	Deployments []DeploymentStatus `json:"deployments,omitempty"`
	// admissionReady is nil for components without webhooks.
	// +optional
	AdmissionReady *bool `json:"admissionReady,omitempty"`
	// retainedResources lists objects that outlive a manager-level disable: agent DaemonSets and
	// their native configs, and native objects the stopped manager would have reconciled (for
	// example an active NodeMaintenance). Non-empty means DisableIncomplete.
	// +optional
	RetainedResources []string `json:"retainedResources,omitempty"`
	// +optional
	Message string `json:"message,omitempty"`
}

// ImageReference is one configured image pull reference in the release set.
type ImageReference struct {
	Name  string `json:"name"`
	Image string `json:"image"`
}

// WorkloadAvailabilityConfigStatus defines the observed state.
type WorkloadAvailabilityConfigStatus struct {
	// Configuration generation last processed by WAO.
	// +operator-sdk:csv:customresourcedefinitions:type=status,displayName="Observed Generation",xDescriptors={"urn:alm:descriptor:text"},order=3
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// Available, Progressing, and Degraded describe WAO reconciliation.
	// Available means reconciliation succeeded, including when all components
	// are Disabled; it does not mean workloads are protected. Check component
	// status for retained resources after disabling.
	// +operator-sdk:csv:customresourcedefinitions:type=status,displayName="Reconciliation Conditions",xDescriptors={"urn:alm:descriptor:io.kubernetes.conditions"},order=1
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
	// +optional
	Components []ComponentStatus `json:"components,omitempty"`
	// Namespace where WAO installs component operators.
	// +operator-sdk:csv:customresourcedefinitions:type=status,displayName="Installation Namespace",xDescriptors={"urn:alm:descriptor:io.kubernetes:Namespace"},order=2
	// +optional
	InstallNamespace string `json:"installNamespace,omitempty"`
	// +optional
	ReleaseSet []ImageReference `json:"releaseSet,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=wac
// +kubebuilder:printcolumn:name="Available",type=string,JSONPath=`.status.conditions[?(@.type=="Available")].status`
// +kubebuilder:printcolumn:name="Progressing",type=string,JSONPath=`.status.conditions[?(@.type=="Progressing")].status`
// +kubebuilder:printcolumn:name="Degraded",type=string,JSONPath=`.status.conditions[?(@.type=="Degraded")].status`
// +kubebuilder:validation:XValidation:rule="self.metadata.name == 'cluster'",message="WorkloadAvailabilityConfig is a singleton and must be named 'cluster'"
// +operator-sdk:csv:customresourcedefinitions:resources={{Deployment,v1,""},{Service,v1,""},{ConfigMap,v1,""},{ValidatingWebhookConfiguration,v1,""},{MutatingWebhookConfiguration,v1,""}}

// WorkloadAvailabilityConfig provides cluster-wide configuration for the six
// medik8s component operators. WAO automatically creates this cluster-scoped
// singleton with the name cluster and all components Disabled. Edit the existing
// cluster resource to configure components. When creating it manually, use the
// name cluster.
type WorkloadAvailabilityConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WorkloadAvailabilityConfigSpec   `json:"spec,omitempty"`
	Status WorkloadAvailabilityConfigStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WorkloadAvailabilityConfigList contains a list of WorkloadAvailabilityConfig.
type WorkloadAvailabilityConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WorkloadAvailabilityConfig `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WorkloadAvailabilityConfig{}, &WorkloadAvailabilityConfigList{})
}
