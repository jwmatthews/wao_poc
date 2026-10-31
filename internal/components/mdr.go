package components

import (
	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/images"
)

func MDR() Definition {
	return Definition{
		Key: v1alpha1.ComponentKeyMachineDeletionRemediation, ShortName: "mdr", ManifestDir: "mdr",
		ManagerDeployment: "machine-deletion-remediation-controller-manager",
		ManagerContainer:  "manager",
		Deployments:       []string{"machine-deletion-remediation-controller-manager"},
		Images:            []string{images.MDRManager},
		ManagedKinds:      []ResourceKind{{Group: "machine-deletion-remediation.medik8s.io", Version: "v1alpha1", Kind: "MachineDeletionRemediation"}},
	}
}
