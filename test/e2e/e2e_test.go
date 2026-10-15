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

package e2e

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	appsv1 "k8s.io/api/apps/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/medik8s/workload-availability-operator/api/v1alpha1"
	"github.com/medik8s/workload-availability-operator/internal/components"
	"github.com/medik8s/workload-availability-operator/internal/images"
	"github.com/medik8s/workload-availability-operator/internal/operands"
)

var _ = Describe("All-Disabled install", Ordered, func() {
	BeforeAll(func() {
		By("installing CRDs and waiting for their APIs")
		_, err := kubectl("apply", "-f", "config/crd/bases")
		Expect(err).NotTo(HaveOccurred())
		_, err = kubectl("wait", "--for=condition=Established", "--timeout=60s", "-f", "config/crd/bases")
		Expect(err).NotTo(HaveOccurred())

		By("installing WAO in its configured namespace")
		_, err = kubectl("apply", "-f", manifestPath)
		Expect(err).NotTo(HaveOccurred())
		_, err = kubectl("label", "namespace", namespace,
			"pod-security.kubernetes.io/enforce=restricted", "--overwrite")
		Expect(err).NotTo(HaveOccurred())
	})

	AfterAll(func() {
		By("deleting the singleton while the manager and its RBAC still exist")
		_, err := kubectl("delete", "workloadavailabilityconfig", v1alpha1.SingletonName,
			"--ignore-not-found", "--timeout=60s")
		// If finalization fails, leave the manager available for diagnosis; the
		// outer runner still deletes the entire disposable cluster.
		Expect(err).NotTo(HaveOccurred(), "default config finalization failed")

		By("removing the saved install manifests after finalization")
		_, err = kubectl("delete", "-f", manifestPath, "--ignore-not-found", "--timeout=60s")
		Expect(err).NotTo(HaveOccurred(), "install cleanup failed")
	})

	AfterEach(func() {
		if !CurrentSpecReport().Failed() {
			return
		}
		for _, args := range [][]string{
			{"logs", "deployment/" + managerName, "-n", namespace, "--all-containers", "--tail=200"},
			{"get", "events", "-n", namespace, "--sort-by=.lastTimestamp"},
			{"describe", "deployment", managerName, "-n", namespace},
		} {
			output, err := kubectl(args...)
			_, _ = fmt.Fprintf(GinkgoWriter, "%s\nerror: %v\n", output, err)
		}
	})

	It("runs a ready manager", func() {
		Eventually(func(g Gomega) {
			var deployment appsv1.Deployment
			output, err := kubectl("get", "deployment", managerName, "-n", namespace, "-o", "json")
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(json.Unmarshal([]byte(output), &deployment)).To(Succeed())
			g.Expect(deployment.Status.ObservedGeneration).To(Equal(deployment.Generation))
			g.Expect(deployment.Status.UpdatedReplicas).To(Equal(int32(1)))
			g.Expect(deployment.Status.ReadyReplicas).To(Equal(int32(1)))
			g.Expect(deployment.Status.AvailableReplicas).To(Equal(int32(1)))
			g.Expect(deployment.Spec.Template.Spec.Containers[0].Image).To(Equal(projectImage))
		}, 2*time.Minute, time.Second).Should(Succeed())
	})

	It("bootstraps the singleton with every component Disabled", func() {
		Eventually(func(g Gomega) {
			var config v1alpha1.WorkloadAvailabilityConfig
			output, err := kubectl("get", "workloadavailabilityconfig", v1alpha1.SingletonName, "-o", "json")
			g.Expect(err).NotTo(HaveOccurred())
			g.Expect(json.Unmarshal([]byte(output), &config)).To(Succeed())
			g.Expect(config.Status.ObservedGeneration).To(Equal(config.Generation))
			g.Expect(config.Status.InstallNamespace).To(Equal(namespace))
			g.Expect(config.Status.ReleaseSet).To(HaveLen(len(images.Required)))
			g.Expect(config.Status.Components).To(HaveLen(len(components.All())))
			names := make([]string, 0, len(config.Status.Components))
			for _, status := range config.Status.Components {
				names = append(names, status.Name)
				g.Expect(config.Spec.StateOf(status.Name)).To(Equal(v1alpha1.ComponentStateDisabled))
				g.Expect(status.DesiredState).To(Equal(v1alpha1.ComponentStateDisabled))
				g.Expect(status.Phase).To(Equal(v1alpha1.ComponentPhaseDisabled))
				g.Expect(status.Deployments).To(BeEmpty())
				g.Expect(status.RetainedResources).To(BeEmpty())
				if status.AdmissionReady != nil {
					g.Expect(*status.AdmissionReady).To(BeFalse())
				}
			}
			g.Expect(names).To(ConsistOf(
				v1alpha1.ComponentKeyNodeHealthCheck, v1alpha1.ComponentKeySelfNodeRemediation,
				v1alpha1.ComponentKeyStorageBasedRemediation, v1alpha1.ComponentKeyFenceAgentsRemediation,
				v1alpha1.ComponentKeyMachineDeletionRemediation, v1alpha1.ComponentKeyNodeMaintenance))
			g.Expect(meta.IsStatusConditionTrue(config.Status.Conditions, v1alpha1.ConditionAvailable)).To(BeTrue())
			g.Expect(meta.IsStatusConditionFalse(config.Status.Conditions, v1alpha1.ConditionProgressing)).To(BeTrue())
			g.Expect(meta.IsStatusConditionFalse(config.Status.Conditions, v1alpha1.ConditionDegraded)).To(BeTrue())
		}, 2*time.Minute, time.Second).Should(Succeed())
	})

	It("creates no operands, node agents, admission configurations or native resources", func() {
		var workloads unstructured.UnstructuredList
		output, err := kubectl("get", "deployments,daemonsets,services", "-n", namespace, "-o", "json")
		Expect(err).NotTo(HaveOccurred())
		Expect(json.Unmarshal([]byte(output), &workloads)).To(Succeed())
		Expect(workloads.Items).To(HaveLen(1))
		Expect(workloads.Items[0].GetKind()).To(Equal("Deployment"))
		Expect(workloads.Items[0].GetName()).To(Equal(managerName))

		var admission unstructured.UnstructuredList
		output, err = kubectl("get", "mutatingwebhookconfigurations,validatingwebhookconfigurations",
			"-l", operands.LabelManagedBy+"="+operands.ManagedByValue, "-o", "json")
		Expect(err).NotTo(HaveOccurred())
		Expect(json.Unmarshal([]byte(output), &admission)).To(Succeed())
		Expect(admission.Items).To(BeEmpty())

		var crds apiextensionsv1.CustomResourceDefinitionList
		output, err = kubectl("get", "crds", "-o", "json")
		Expect(err).NotTo(HaveOccurred())
		Expect(json.Unmarshal([]byte(output), &crds)).To(Succeed())
		nativeCount := 0
		for _, crd := range crds.Items {
			if !strings.HasSuffix(crd.Spec.Group, ".medik8s.io") || crd.Spec.Group == v1alpha1.GroupVersion.Group {
				continue
			}
			nativeCount++
			var objects unstructured.UnstructuredList
			output, err = kubectl("get", crd.Name, "--all-namespaces", "-o", "json")
			Expect(err).NotTo(HaveOccurred())
			Expect(json.Unmarshal([]byte(output), &objects)).To(Succeed())
			Expect(objects.Items).To(BeEmpty(), "install created native resources of kind %s", crd.Spec.Names.Kind)
		}
		Expect(nativeCount).To(Equal(12))
	})
})
