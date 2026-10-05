package components

import (
	"github.com/jwmatthews/wao_poc/api/v1alpha1"
	"github.com/jwmatthews/wao_poc/internal/images"
)

func SBR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyStorageBasedRemediation, ShortName: "sbr", ManifestDir: "sbr",
		Deployments: []string{"sbr-operator-controller-manager"},
		Images: []ImageBinding{
			{Env: images.SBRManager, Original: "quay.io/medik8s/storage-based-remediation-operator:v0.3.0"},
			{Env: images.SBRAgent, Original: "quay.io/medik8s/storage-based-remediation-agent:v0.3.0"},
		},
		AgentOwners:  []ResourceKind{{Group: "storage-based-remediation.medik8s.io", Version: "v1alpha1", Kind: "StorageBasedRemediationConfig"}},
		ManagedKinds: []ResourceKind{{Group: "storage-based-remediation.medik8s.io", Version: "v1alpha1", Kind: "StorageBasedRemediation"}},
	}
}
