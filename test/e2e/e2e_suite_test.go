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
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	namespace    = "openshift-workload-availability"
	managerName  = "workload-availability-operator-controller-manager"
	projectImage = "example.com/workload-availability-operator:v0.0.1"
)

var projectDir, manifestPath string

// TestE2E tests a fresh Kind cluster created by run.py. Full operand installation
// and OpenShift admission are covered separately by test/cluster.
func TestE2E(t *testing.T) {
	for _, key := range []string{"KUBECONFIG", "KIND_CLUSTER", "RUN_DIR"} {
		if os.Getenv(key) == "" {
			t.Fatalf("%s is required; use make test-e2e to create an isolated Kind cluster", key)
		}
	}
	var err error
	projectDir, err = filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	manifestPath = filepath.Join(os.Getenv("RUN_DIR"), "install.yaml")
	RegisterFailHandler(Fail)
	RunSpecs(t, "WAO all-Disabled install")
}

var _ = BeforeSuite(func() {
	By("checking the explicit kubeconfig selects the dedicated Kind cluster")
	output, err := kubectl("config", "current-context")
	Expect(err).NotTo(HaveOccurred())
	Expect(output).To(Equal("kind-" + os.Getenv("KIND_CLUSTER") + "\n"))

	By("rendering the test overlay without modifying the committed image pin")
	output, err = runCommand(time.Minute, tool("KUSTOMIZE", "bin/kustomize"), "build", "config/e2e")
	Expect(err).NotTo(HaveOccurred())
	Expect(os.WriteFile(manifestPath, []byte(output), 0o600)).To(Succeed())

	By("building and loading the WAO image")
	_, err = runCommand(10*time.Minute, "make", "docker-build", "IMG="+projectImage)
	Expect(err).NotTo(HaveOccurred())
	_, err = runCommand(2*time.Minute, tool("KIND", "kind"),
		"load", "docker-image", projectImage, "--name", os.Getenv("KIND_CLUSTER"))
	Expect(err).NotTo(HaveOccurred())
})

func tool(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func kubectl(args ...string) (string, error) {
	args = append([]string{"--kubeconfig", os.Getenv("KUBECONFIG"), "--request-timeout=20s"}, args...)
	return runCommand(90*time.Second, tool("KUBECTL", "kubectl"), args...)
}

// Every subprocess is bounded, including cleanup. run.py captures all output in
// evidence/ and deletes the Kind cluster even if this suite fails or times out.
func runCommand(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = projectDir
	cmd.WaitDelay = 5 * time.Second
	_, _ = fmt.Fprintf(GinkgoWriter, "running: %s %q\n", name, args)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("%s failed: %w\n%s", name, err, output)
	}
	return string(output), nil
}
