#!/usr/bin/env bash
# test/cluster/11-parity.sh — WAO-INST-11: live operand Deployments and RBAC (incl. the OLM all-namespaces copies) equal the upstream bundles. Read-only.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-11 parity, all six"
parity_ok() { # parity_ok COMPONENT : run parity.py, keep its diff output in raw/
  local code=0
  "$PYTHON" "${REPO_ROOT}/test/cluster/parity.py" --component "$1" --namespace "$NS" \
    >"${RUN_DIR}/raw/11-parity-$1.txt" 2>&1 || code=$?
  cat "${RUN_DIR}/raw/11-parity-$1.txt"
  return $code
}
rc=0
for c in nhc snr sbr far mdr nmo; do
  expect "parity.py --component $c exits 0" parity_ok "$c" || rc=1   # check all six before failing
done

snr_pinned=$("$PYTHON" -c '
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["components"]["snr"]["images"]["RELATED_IMAGE_SNR_MANAGER"]["pinned"])' \
  "${REPO_ROOT}/release-set.yaml")
export SNR_PINNED="$snr_pinned"
expect "SNR agent DaemonSet image equals the pinned SNR digest" \
  jcheck 'all(c["image"] == os.environ["SNR_PINNED"] for c in o["spec"]["template"]["spec"]["containers"] + (o["spec"]["template"]["spec"].get("initContainers") or []))' \
  get daemonset self-node-remediation-ds -n "$NS" || rc=1
record 11-operand-images get deployment,daemonset -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}' >/dev/null || true
snapshot 11
exit $rc
