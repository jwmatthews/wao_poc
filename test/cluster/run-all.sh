#!/usr/bin/env bash
# test/cluster/run-all.sh — run the live-cluster install cases WAO-INST-00..18 in order and write results.json.
#
# Usage: KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/run-all.sh [NN ...]
#   With no arguments every case runs. With arguments only those case numbers run (e.g. `00` or `05 06`).
# Environment:
#   STOP_ON_FAIL=1   after a failed case, mark the remaining cases blocked (cleanup still runs)
#   SKIP_CLEANUP=1   do not run WAO-INST-18 automatically (leave the cluster for inspection)
#   RUN_DIR=...      evidence directory (default evidence/<UTC date>-wao-poc, fixed for the whole run)
#
# Policy: a failed preflight (00) stops the run before anything is changed. A failed catalog or install
# (01, 02) blocks 03..17 and goes straight to cleanup. Other failures are recorded and the run continues,
# because each case reports its own state; WAO-INST-18 always runs last (unless SKIP_CLEANUP=1) so the
# disposable cluster is left passing preflight again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${KUBECONFIG:?set KUBECONFIG to a disposable OpenShift cluster you are authorized to modify}"
export RUN_DIR="${RUN_DIR:-$(cd "$HERE/../.." && pwd)/evidence/$(date -u +%F)-wao-poc}"
source "$HERE/env.sh"
RESULTS=(python3 "$HERE/results.py")

ALL="00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18"
CASES="${*:-$ALL}"

if [ ! -f "$RUN_DIR/RUN.md" ]; then
  cat >"$RUN_DIR/RUN.md" <<'MD'
# WAO POC live-cluster run

Raw output in this directory is git-ignored and may contain cluster-identifying details.

## Intended mutations
- Apply the ConfigMap-backed CatalogSource `wao-poc-catalog` in `openshift-marketplace`.
- Create namespace `openshift-workload-availability`, an OperatorGroup and a Manual Subscription; approve the InstallPlan.
- Enable each of the six components in turn. Enabling SNR starts privileged SNR agents on every eligible node (D3).
- Server dry-run admission probes only. No NodeHealthCheck, StorageBasedRemediationConfig, FenceAgentsRemediation,
  MachineDeletionRemediation, NodeMaintenance or SelfNodeRemediation is ever created.
- Enabling NHC also adds `node-remediation-console-plugin` to `Console/cluster` `spec.plugins` (administrator step,
  preserving other entries) and runs one short-lived curl pod in the install namespace; disabling NHC removes the entry.
- Delete the WAO pod (twice), scale the SBR manager to 0 once, disable components, delete the config.
- Case 05 runs read-only `curl` queries via `oc exec` inside `openshift-monitoring/prometheus-k8s-0`.
- Case 13 deletes and re-annotates the WAO-owned ConfigMap `node-healthcheck-ca-bundle` once; WAO restores it.

## Cleanup (WAO-INST-18)
- Delete the config, Subscription and CSV; record leftovers; delete the SNR config (agents stop), template and
  Secret, the thirteen CRDs, the NHC aggregation role and binding, the ConsolePlugin, `medik8s-leases` if present,
  the catalog and the namespace.
- Kept deliberately: the image build namespace `wao-poc-build`.
MD
fi

blocked=""      # case numbers forced to blocked
any_fail=0
run_case() { # run_case NN : run one case script, record its outcome
  local n="$1" id="WAO-INST-$1" script log code
  script=$(ls "$HERE/$n"-*.sh 2>/dev/null | head -1)
  if [ -z "$script" ]; then echo "no script for $id" >&2; return 2; fi
  log="$RUN_DIR/raw/case-$n.log"
  echo "################ $id ($(basename "$script")) $(date -u +%FT%TZ)"
  bash "$script" 2>&1 | tee "$log"
  code=${PIPESTATUS[0]}
  if [ "$code" -eq 0 ]; then
    "${RESULTS[@]}" record --run-dir "$RUN_DIR" --id "$id" --status pass --log "$log"
  else
    any_fail=1
    "${RESULTS[@]}" record --run-dir "$RUN_DIR" --id "$id" --status fail --notes "exit $code" --log "$log"
  fi
  echo "################ $id exit $code"
  return "$code"
}
block() { # block REASON NN... : record cases as blocked
  local reason="$1" n; shift
  for n in "$@"; do
    case " $blocked " in *" $n "*) continue ;; esac
    blocked="$blocked $n"
    "${RESULTS[@]}" record --run-dir "$RUN_DIR" --id "WAO-INST-$n" --status blocked --notes "$reason"
  done
}
later_than() { # later_than NN : the selected cases after NN, excluding 18
  local n; for n in $CASES; do [ "$n" != 18 ] && [ "$((10#$n))" -gt "$((10#$1))" ] && echo "$n"; done
}

for n in $CASES; do
  case " $blocked " in *" $n "*) continue ;; esac
  if [ "$n" = 18 ] && [ "${SKIP_CLEANUP:-0}" = 1 ]; then
    block "skipped (SKIP_CLEANUP=1)" 18; continue
  fi
  if run_case "$n"; then continue; fi
  case "$n" in
    00) block "preflight failed" $(later_than 00)
        case " $CASES " in *" 18 "*) block "preflight failed; nothing to clean up" 18 ;; esac
        break ;;
    01|02) block "WAO install (WAO-INST-$n) failed" $(later_than "$n") ;;
    18) ;;
    *) [ "${STOP_ON_FAIL:-0}" = 1 ] && block "stopped after WAO-INST-$n failed (STOP_ON_FAIL=1)" $(later_than "$n") ;;
  esac
done

echo "################ results"
"${RESULTS[@]}" build --run-dir "$RUN_DIR"
echo "results: $RUN_DIR/results.json"
exit "$any_fail"
