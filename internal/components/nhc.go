package components

import (
	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/images"
)

func NHC() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyNodeHealthCheck, ShortName: "nhc", ManifestDir: "nhc",
		Deployments: []string{"node-healthcheck-controller-manager"},
		Images: []ImageBinding{
			{Env: images.NHCManager, Original: "quay.io/medik8s/node-healthcheck-operator:v5.8.0"},
		},
		Webhooks:     []WebhookConfiguration{{Kind: "ValidatingWebhookConfiguration", Name: "node-healthcheck-validating-webhook-configuration"}},
		ManagedKinds: []ResourceKind{{Group: "remediation.medik8s.io", Version: "v1alpha1", Kind: "NodeHealthCheck"}},
	}
}
