#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the target cluster kubeconfig}"

oc --kubeconfig "$KUBECONFIG" patch workloadavailabilityconfig cluster --type merge \
  -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"},"selfNodeRemediation":{"state":"Enabled"},"storageBasedRemediation":{"state":"Enabled"},"fenceAgentsRemediation":{"state":"Enabled"},"machineDeletionRemediation":{"state":"Enabled"},"nodeMaintenance":{"state":"Enabled"}}}}'
