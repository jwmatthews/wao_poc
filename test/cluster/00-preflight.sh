#!/usr/bin/env bash
# test/cluster/00-preflight.sh — WAO-INST-00: the cluster is suitable and clean. Read-only.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-00 preflight (read-only)"
record 00-clusterversion get clusterversion version -o json >/dev/null
record 00-nodes get nodes -o json >/dev/null
record 00-clusteroperators get clusteroperators >/dev/null

topology=$(k get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
expect "control-plane topology '$topology' is supported by NHC admission" \
  grep -Eqx 'HighlyAvailable|SingleReplica|HighlyAvailableArbiter|External' <<<"$topology"

all_amd64() {
  local arch
  arch=$(k get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}') || return 1
  [ -n "$arch" ] && ! printf '%s\n' "$arch" | grep -vqx amd64
}
expect "all nodes are linux/amd64 (the pinned operand images are amd64-only)" all_amd64
expect "classic OLM is present" found crd catalogsources.operators.coreos.com
expect "classic OLM is present (Subscription API)" found crd subscriptions.operators.coreos.com

no_medik8s_crds() { local c; c=$(k get crd -o name) || return 1; ! printf '%s\n' "$c" | grep -q 'medik8s\.io'; }
expect "no medik8s CRDs exist (remove standalone medik8s operators and their CRDs first)" no_medik8s_crds

no_medik8s_csvs() {
  local c; c=$(k get csv -A -o name) || return 1
  ! printf '%s\n' "$c" | grep -Eq 'node-healthcheck|self-node-remediation|storage-based-remediation|fence-agents-remediation|machine-deletion-remediation|node-maintenance|workload-availability-operator'
}
expect "no standalone medik8s operator CSVs (and no WAO CSV) exist" no_medik8s_csvs
expect "namespace $NS does not exist yet" absent namespace "$NS"

if record 00-machine-api get crd machines.machine.openshift.io -o name >/dev/null 2>&1; then
  machine_api=present
else
  machine_api=absent
  echo "note: Machine API absent; MDR can be installed but cannot act"
fi
if ! absent catalogsource "$CATALOG" -n "$CAT_NS" >/dev/null 2>&1; then
  echo "note: CatalogSource $CATALOG already exists in $CAT_NS (WAO-INST-01 re-applies it)"
fi

# The bundle's WAO image must be pullable. When it points at the internal registry, the image
# stream image must exist (the build namespace is deliberately kept between runs).
wao_image=$(grep -m1 -Eo 'image: image-registry\.openshift-image-registry\.svc:5000/[^ ]+' \
  "${REPO_ROOT}/bundle/manifests/workload-availability-operator.clusterserviceversion.yaml" | sed 's/^image: //' || true)
if [ -n "$wao_image" ]; then
  path="${wao_image#image-registry.openshift-image-registry.svc:5000/}"   # <ns>/<name>@sha256:...
  img_ns="${path%%/*}"; img_ref="${path#*/}"
  expect "WAO image $img_ref exists in the internal registry (namespace $img_ns)" found imagestreamimage "$img_ref" -n "$img_ns"
else
  echo "note: WAO image is not in the internal registry; check it is pullable by the cluster"
fi

version=$(k get clusterversion version -o jsonpath='{.status.desired.version}')
nodes=$(k get nodes -o name | wc -l | tr -d ' ')
cp_nodes=$(k get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l | tr -d ' ')
{
  echo
  echo "## Preflight $(date -u +%FT%TZ)"
  echo "- OpenShift version: ${version}"
  echo "- Nodes: ${nodes} (control-plane: ${cp_nodes}); topology: ${topology}"
  echo "- Machine API: ${machine_api}"
} >> "${RUN_DIR}/RUN.md"
echo "note: OpenShift ${version}, ${nodes} nodes, topology ${topology}, Machine API ${machine_api}"
echo "Preflight passed."
