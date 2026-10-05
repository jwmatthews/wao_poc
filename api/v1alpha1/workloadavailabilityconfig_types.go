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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ComponentState is the administrator's intent for one component.
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
	// state requests the component to be installed (Enabled) or removed at the
	// manager level (Disabled). Unset means Disabled.
	// +kubebuilder:default=Disabled
	// +optional
	State ComponentState `json:"state,omitempty"`
}

// ComponentsSpec holds per-component intent. Every component defaults to Disabled.
type ComponentsSpec struct {
	// +optional
	NodeHealthCheck ComponentSpec `json:"nodeHealthCheck,omitempty"`
	// +optional
	SelfNodeRemediation ComponentSpec `json:"selfNodeRemediation,omitempty"`
	// +optional
	StorageBasedRemediation ComponentSpec `json:"storageBasedRemediation,omitempty"`
	// +optional
	NodeMaintenance ComponentSpec `json:"nodeMaintenance,omitempty"`
	// +optional
	FenceAgentsRemediation ComponentSpec `json:"fenceAgentsRemediation,omitempty"`
	// +optional
	MachineDeletionRemediation ComponentSpec `json:"machineDeletionRemediation,omitempty"`
}

// WorkloadAvailabilityConfigSpec defines the desired state of the installation.
type WorkloadAvailabilityConfigSpec struct {
	// +optional
	Components ComponentsSpec `json:"components,omitempty"`
}

// StateOf returns the effective state for a component key; unknown keys and
// unset entries are Disabled.
func (s *WorkloadAvailabilityConfigSpec) StateOf(key string) ComponentState {
	var c ComponentSpec
	switch key {
	case ComponentKeyNodeHealthCheck:
		c = s.Components.NodeHealthCheck
	case ComponentKeySelfNodeRemediation:
		c = s.Components.SelfNodeRemediation
	case ComponentKeyStorageBasedRemediation:
		c = s.Components.StorageBasedRemediation
	case ComponentKeyNodeMaintenance:
		c = s.Components.NodeMaintenance
	case ComponentKeyFenceAgentsRemediation:
		c = s.Components.FenceAgentsRemediation
	case ComponentKeyMachineDeletionRemediation:
		c = s.Components.MachineDeletionRemediation
	default:
		return ComponentStateDisabled
	}
	if c.State == ComponentStateEnabled {
		return ComponentStateEnabled
	}
	return ComponentStateDisabled
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

// ImageReference is one pinned image in the release set.
type ImageReference struct {
	Name  string `json:"name"`
	Image string `json:"image"`
}

// WorkloadAvailabilityConfigStatus defines the observed state.
type WorkloadAvailabilityConfigStatus struct {
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
	// +optional
	Components []ComponentStatus `json:"components,omitempty"`
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

// WorkloadAvailabilityConfig is the cluster-scoped singleton entry point.
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
