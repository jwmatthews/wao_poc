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
	// Enabled runs the operator. Disabled removes its manager and managed
	// installation resources; existing agents, configuration, and native resources
	// can remain. Complete active maintenance or remediation before disabling.
	// Default: Disabled.
	// +operator-sdk:csv:customresourcedefinitions:type=spec,displayName="State",xDescriptors={"urn:alm:descriptor:com.tectonic.ui:select:Disabled","urn:alm:descriptor:com.tectonic.ui:select:Enabled"}
	// +kubebuilder:default=Disabled
	// +optional
	State ComponentState `json:"state,omitempty"`
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
