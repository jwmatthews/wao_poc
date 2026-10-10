package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func NHC() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyNodeHealthCheck, ShortName: "nhc", ManifestDir: "nhc",
		// The manager first: tests and parity use Deployments[0] as the manager ServiceAccount name.
		// The console backend is the OpenShift dynamic plugin server NHC registers a ConsolePlugin for (issue #4).
		Deployments: []string{"node-healthcheck-controller-manager", "node-healthcheck-node-remediation-console-plugin"},
		Images: []ImageBinding{
			{Env: images.NHCManager, Original: "quay.io/medik8s/node-healthcheck-operator:v0.12.0"},
			{Env: images.NHCConsole, Original: "quay.io/medik8s/node-remediation-console:v0.12.0"},
		},
		Webhooks:     []WebhookConfiguration{{Kind: "ValidatingWebhookConfiguration", Name: "node-healthcheck-validating-webhook-configuration"}},
		ManagedKinds: []ResourceKind{{Group: "remediation.medik8s.io", Version: "v1alpha1", Kind: "NodeHealthCheck"}},
	}
}
