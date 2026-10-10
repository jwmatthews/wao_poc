# test/cluster/env.sh
# shellcheck shell=bash
: "${KUBECONFIG:?set KUBECONFIG to a disposable OpenShift cluster you are authorized to modify}"
export KUBECONFIG
export REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export OC="${OC:-oc}"                                  # oc or kubectl
export PYTHON="${PYTHON:-${REPO_ROOT}/.venv/bin/python}" # needs PyYAML (parity.py)
export NS="${NS:-openshift-workload-availability}"
export PACKAGE="${PACKAGE:-workload-availability-operator}"
export CHANNEL="${CHANNEL:-alpha}"
export CSV_NAME="${CSV_NAME:-workload-availability-operator.v0.1.0}"
export CLUSTERCATALOG="${CLUSTERCATALOG:-wao-poc}"
export CLUSTERCATALOG_FILE="${CLUSTERCATALOG_FILE:-${REPO_ROOT}/dist/wao-poc-clustercatalog.yaml}"
export CE_NAME="${CE_NAME:-workload-availability-operator}"
export OLMV1_DIR="${OLMV1_DIR:-${REPO_ROOT}/config/olmv1}"
export WAO_DEPLOYMENT="${WAO_DEPLOYMENT:-workload-availability-operator-controller-manager}"
export WAO_POD_SELECTOR="${WAO_POD_SELECTOR:-app.kubernetes.io/name=workload-availability-operator,control-plane=controller-manager}"
export BUILD_NS="${BUILD_NS:-wao-poc-build}"            # image build namespace; deliberately kept by cleanup
export MANIFESTS="${MANIFESTS:-${REPO_ROOT}/internal/operands/manifests}"
export RUN_DIR="${RUN_DIR:-${REPO_ROOT}/evidence/$(date -u +%F)-wao-poc}"   # git-ignored
mkdir -p "${RUN_DIR}/raw"
