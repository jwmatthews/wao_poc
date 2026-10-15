package components

import (
	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/images"
)

func NMO() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyNodeMaintenance, ShortName: "nmo", ManifestDir: "nmo",
		Deployments: []string{"node-maintenance-operator-controller-manager"},
		Images: []ImageBinding{
			{Env: images.NMOManager, Original: "quay.io/medik8s/node-maintenance-operator:v0.21.0"},
		},
		Webhooks:     []WebhookConfiguration{{Kind: "ValidatingWebhookConfiguration", Name: "node-maintenance-operator-validating-webhook-configuration"}},
		ManagedKinds: []ResourceKind{{Group: "nodemaintenance.medik8s.io", Version: "v1beta1", Kind: "NodeMaintenance"}},
	}
}
