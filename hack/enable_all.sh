#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the target cluster kubeconfig}"

oc --kubeconfig "$KUBECONFIG" patch workloadavailabilityconfig cluster --type merge \
  -p '{"spec":{"components":{"nodeHealthCheck":{"enabled":true},"selfNodeRemediation":{"enabled":true},"storageBasedRemediation":{"enabled":true},"fenceAgentsRemediation":{"enabled":true},"machineDeletionRemediation":{"enabled":true},"nodeMaintenance":{"enabled":true}}}}'
