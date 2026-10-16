package components

import (
	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/images"
)

func SNR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeySelfNodeRemediation, ShortName: "snr", ManifestDir: "snr",
		Deployments: []string{"self-node-remediation-controller-manager"},
		Images: []ImageBinding{
			{Env: images.SNRManager, Original: "quay.io/medik8s/self-node-remediation-operator:v0.13.0"},
		},
		Webhooks: []WebhookConfiguration{
			{Kind: "ValidatingWebhookConfiguration", Name: "self-node-remediation-validating-webhook-configuration"},
			{Kind: "MutatingWebhookConfiguration", Name: "self-node-remediation-mutating-webhook-configuration"},
		},
		AgentOwners:  []ResourceKind{{Group: "self-node-remediation.medik8s.io", Version: "v1alpha1", Kind: "SelfNodeRemediationConfig"}},
		ManagedKinds: []ResourceKind{{Group: "self-node-remediation.medik8s.io", Version: "v1alpha1", Kind: "SelfNodeRemediation"}},
	}
}
