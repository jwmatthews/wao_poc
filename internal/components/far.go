package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func FAR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyFenceAgentsRemediation, ShortName: "far", ManifestDir: "far",
		Deployments: []string{"fence-agents-remediation-controller-manager"},
		Images: []ImageBinding{
			{Env: images.FARManager, Original: "quay.io/medik8s/fence-agents-remediation-operator:v0.8.0"},
		},
		Webhooks: []WebhookConfiguration{
			{Kind: "ValidatingWebhookConfiguration", Name: "fence-agents-remediation-validating-webhook-configuration"},
			{Kind: "MutatingWebhookConfiguration", Name: "fence-agents-remediation-mutating-webhook-configuration"},
		},
		ManagedKinds: []ResourceKind{{Group: "fence-agents-remediation.medik8s.io", Version: "v1alpha1", Kind: "FenceAgentsRemediation"}},
	}
}
