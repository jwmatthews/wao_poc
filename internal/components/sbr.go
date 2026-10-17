package components

import (
	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/images"
)

func SBR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyStorageBasedRemediation, ShortName: "sbr", ManifestDir: "sbr",
		Deployments: []string{"sbr-operator-controller-manager"},
		Images: []ImageBinding{
			imageBinding(images.SBRManager),
			imageBinding(images.SBRAgent),
		},
		AgentOwners:  []ResourceKind{{Group: "storage-based-remediation.medik8s.io", Version: "v1alpha1", Kind: "StorageBasedRemediationConfig"}},
		ManagedKinds: []ResourceKind{{Group: "storage-based-remediation.medik8s.io", Version: "v1alpha1", Kind: "StorageBasedRemediation"}},
	}
}
