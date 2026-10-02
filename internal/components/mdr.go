package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func MDR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyMachineDeletionRemediation, ShortName: "mdr", ManifestDir: "mdr",
		Deployments: []string{"machine-deletion-remediation-controller-manager"},
		Images: []ImageBinding{
			{Env: images.MDRManager, Original: "quay.io/medik8s/machine-deletion-remediation-operator:v0.7.0"},
		},
		ManagedKinds: []ResourceKind{{Group: "machine-deletion-remediation.medik8s.io", Version: "v1alpha1", Kind: "MachineDeletionRemediation"}},
	}
}
