# test/olmv1/env.sh — settings for the OLM v1 (ClusterExtension) experiments.
# shellcheck shell=bash
: "${KUBECONFIG:?set KUBECONFIG to a disposable OpenShift cluster you are authorized to modify}"
export KUBECONFIG
export REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export OC="${OC:-oc}"
export PYTHON="${PYTHON:-${REPO_ROOT}/.venv/bin/python}"
export NS="${NS:-openshift-workload-availability}"
export CATALOG_NAME="${CATALOG_NAME:-openshift-redhat-operators}"
export CHANNEL="${CHANNEL:-stable}"
export EXP="${EXP:-0001}"
# Operators in install order. NHC first (no agents), SNR last (arms node agents).
export OPERATORS="${OPERATORS:-nhc nmo mdr far sbr snr}"
export RUN_DIR="${RUN_DIR:-${REPO_ROOT}/evidence/$(date -u +%F)-olmv1-${EXP}}"   # git-ignored
mkdir -p "${RUN_DIR}/raw"

# package name, pinned version, manager Deployment name, owned CRDs per operator key
op_package() {
  case "$1" in
    nhc) echo node-healthcheck-operator ;;
    snr) echo self-node-remediation ;;
    far) echo fence-agents-remediation ;;
    mdr) echo machine-deletion-remediation ;;
    nmo) echo node-maintenance-operator ;;
    sbr) echo storage-based-remediation ;;
    *) echo "unknown operator key: $1" >&2; return 1 ;;
  esac
}
op_version() {
  case "$1" in
    nhc) echo 0.12.1 ;; snr) echo 0.13.1 ;; far) echo 0.8.1 ;;
    mdr) echo 0.7.1 ;; nmo) echo 5.7.1 ;; sbr) echo 0.3.1 ;;
    *) return 1 ;;
  esac
}
op_deployment() {
  case "$1" in
    nhc) echo node-healthcheck-controller-manager ;;
    snr) echo self-node-remediation-controller-manager ;;
    far) echo fence-agents-remediation-controller-manager ;;
    mdr) echo machine-deletion-remediation-controller-manager ;;
    nmo) echo node-maintenance-operator-controller-manager ;;
    sbr) echo sbr-operator-controller-manager ;;   # downstream bundle name
    *) return 1 ;;
  esac
}
op_crds() {
  case "$1" in
    nhc) echo "nodehealthchecks.remediation.medik8s.io" ;;
    snr) echo "selfnoderemediationconfigs.self-node-remediation.medik8s.io selfnoderemediations.self-node-remediation.medik8s.io selfnoderemediationtemplates.self-node-remediation.medik8s.io" ;;
    far) echo "fenceagentsremediations.fence-agents-remediation.medik8s.io fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io" ;;
    mdr) echo "machinedeletionremediations.machine-deletion-remediation.medik8s.io machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io" ;;
    nmo) echo "nodemaintenances.nodemaintenance.medik8s.io" ;;
    sbr) echo "storagebasedremediationconfigs.storage-based-remediation.medik8s.io storagebasedremediations.storage-based-remediation.medik8s.io storagebasedremediationtemplates.storage-based-remediation.medik8s.io" ;;
    *) return 1 ;;
  esac
}
export -f op_package op_version op_deployment op_crds
