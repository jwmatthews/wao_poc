#!/usr/bin/env bash
# test/olmv1/exp0002.sh STEP — experiment 0002: can a ClusterExtension give up a CRD without deleting the
# CRs stored in it? Uses the NHC package only. Each step is run by hand, in order, and inspected before
# the next (bash test/olmv1/exp0002.sh 1 ...). Nothing here touches nodes; NHC CRs created for real are
# inert (selector matches no node). Step 3 deletes the NHC ClusterExtension on purpose, which the 4.22
# docs say deletes its CRDs; the only CRs in that CRD are the two test objects.
EXP=0002 source "$(dirname "$0")/lib.sh"
CE=node-healthcheck-operator
CRD=nodehealthchecks.remediation.medik8s.io
SAMPLE="$(dirname "$0")/samples/nhc-valid.yaml"
step="${1:?step number}"

mk_cr() {  # mk_cr NAME : an inert NodeHealthCheck (selector matches no node)
  sed "s/name: exp0001-nhc/name: $1/" "$SAMPLE"
}
crd_meta() {  # crd_meta LABEL : record CRD labels/annotations/ownerRefs and CR names+UIDs
  record "$1-crd" get crd "$CRD" -o json >/dev/null || true
  k get crd "$CRD" -o json 2>/dev/null | python3 -c '
import json,sys
o=json.load(sys.stdin); m=o["metadata"]
print("  CRD uid", m["uid"]); print("  labels", {k:v for k,v in m.get("labels",{}).items()}); print("  annotations", {k:(v if len(str(v))<60 else str(v)[:57]+"...") for k,v in m.get("annotations",{}).items()}); print("  ownerReferences", m.get("ownerReferences"))' || echo "  CRD absent"
  record "$1-crs" get nodehealthchecks -o json >/dev/null || true
  k get nodehealthchecks -o custom-columns='NAME:.metadata.name,UID:.metadata.uid' 2>/dev/null || echo "  (no CRs / CRD absent)"
}
ce_msg() { k get clusterextension "$1" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null | cut -c1-400; }

case "$step" in
1)
  echo "== 0002-1 baseline: two inert NHC CRs, record CRD ownership metadata"
  expect "NHC extension installed" ce_installed "$CE"
  mk_cr exp0002-a | record 1-create-a create -f - >/dev/null
  mk_cr exp0002-b | record 1-create-b create -f - >/dev/null
  crd_meta 1-baseline | tee "${RUN_DIR}/1-baseline.txt"
  record 1-helm-secrets get secret -n "$NS" -o custom-columns='NAME:.metadata.name,TYPE:.type' >/dev/null
  outcome 0002-1 PASS "baseline recorded"
  ;;
2)
  echo "== 0002-2 collision: a second ClusterExtension for the same package while the first exists"
  sed -e 's/name: node-healthcheck-operator$/name: nhc-second/' "$(dirname "$0")/rbac/nhc/30-clusterextension.yaml" | record 2-create-second apply -f - >/dev/null
  sleep 60
  ce_msg nhc-second | tee "${RUN_DIR}/2-collision.txt"
  crd_meta 2-after-collision | tee -a "${RUN_DIR}/2-collision.txt"
  echo "-- deleting the second extension (it never installed)"
  record 2-delete-second delete clusterextension nhc-second --timeout=120s >/dev/null || true
  wait_for 120 "nhc-second gone" absent clusterextension nhc-second || true
  crd_meta 2-after-second-deleted | tee -a "${RUN_DIR}/2-collision.txt"
  outcome 0002-2 DONE "see 2-collision.txt"
  ;;
3)
  echo "== 0002-3 naive handoff: delete the NHC ClusterExtension and watch the CRD and CRs"
  crd_meta 3-before | tee "${RUN_DIR}/3-naive.txt"
  record 3-delete-ce delete clusterextension "$CE" --timeout=300s >/dev/null || true
  wait_for 300 "extension gone" absent clusterextension "$CE" || true
  sleep 10
  echo "-- after deletion:" | tee -a "${RUN_DIR}/3-naive.txt"
  crd_meta 3-after | tee -a "${RUN_DIR}/3-naive.txt"
  if absent crd "$CRD"; then outcome 0002-3 OBSERVED "CRD deleted with the extension (as documented); CRs gone"; else outcome 0002-3 OBSERVED "CRD SURVIVED extension deletion"; fi
  ;;
4)
  echo "== 0002-4 reinstall, recreate CRs, then protect the CRD and delete the extension again"
  mode="${2:?mode: strip | keep | both}"
  if absent clusterextension "$CE"; then
    record 4-reinstall apply -f "$(dirname "$0")/rbac/nhc/30-clusterextension.yaml" >/dev/null
    wait_for 600 "NHC reinstalled" ce_installed "$CE"
    wait_for 120 "CRD established" crd_established "$CRD"
  fi
  wait_for 300 "NHC manager available" deployment_available node-healthcheck-controller-manager
  wait_for 180 "NHC webhook CA injected" ca_injected validatingwebhookconfiguration/vnodehealthcheck.kb.io
  create_cr_retry() {  # create_cr_retry NAME : the fail-closed webhook may have no endpoints for a while after reinstall
    local n="$1" i
    if ! absent nodehealthcheck "$n"; then return 0; fi
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      if mk_cr "$n" | record "4-create-$n-try$i" create -f - >/dev/null 2>&1; then return 0; fi
      sleep 10
    done
    echo "could not create $n after 12 tries" >&2; return 1
  }
  create_cr_retry exp0002-a
  create_cr_retry exp0002-b
  crd_meta "4-$mode-before" | tee "${RUN_DIR}/4-$mode.txt"
  do_strip=0; do_keep=0; do_foreign=0
  case "$mode" in none) : ;; strip) do_strip=1 ;; keep) do_keep=1 ;; both) do_strip=1; do_keep=1 ;; foreign) do_strip=1; do_foreign=1 ;; *) echo "mode must be none|strip|keep|both|foreign" >&2; exit 2 ;; esac
  if [ "$do_strip" = 1 ]; then
    echo "-- stripping olm.operatorframework.io/* labels and helm/olm annotations from the CRD" | tee -a "${RUN_DIR}/4-$mode.txt"
    for l in $(k get crd "$CRD" -o json | python3 -c 'import json,sys; print(" ".join(k for k in json.load(sys.stdin)["metadata"].get("labels",{}) if k.startswith("olm.operatorframework.io/") or k=="app.kubernetes.io/managed-by"))'); do record "4-strip-label-$(echo $l | tr '/.' '--')" label crd "$CRD" "$l-" >/dev/null; done
    for a in $(k get crd "$CRD" -o json | python3 -c 'import json,sys; print(" ".join(k for k in json.load(sys.stdin)["metadata"].get("annotations",{}) if k.startswith("olm.operatorframework.io/") or k.startswith("meta.helm.sh/")))'); do record "4-strip-ann-$(echo $a | tr '/.' '--')" annotate crd "$CRD" "$a-" >/dev/null; done
    echo "-- removing the controller ownerReference to the ClusterExtension (blockOwnerDeletion=true), otherwise GC deletes the CRD" | tee -a "${RUN_DIR}/4-$mode.txt"
    record 4-strip-ownerref patch crd "$CRD" --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]' >/dev/null
  fi
  if [ "$do_keep" = 1 ]; then
    echo "-- adding helm.sh/resource-policy=keep to the CRD" | tee -a "${RUN_DIR}/4-$mode.txt"
    record 4-keep-annotation annotate crd "$CRD" helm.sh/resource-policy=keep --overwrite >/dev/null
  fi
  if [ "$do_foreign" = 1 ]; then
    echo "-- re-pointing the CRD's Helm release annotations at a different release (exp0002-foreign) to test whether the old release's uninstall skips it" | tee -a "${RUN_DIR}/4-$mode.txt"
    record 4-foreign-annotation annotate crd "$CRD" meta.helm.sh/release-name=exp0002-foreign meta.helm.sh/release-namespace="$NS" --overwrite >/dev/null
    record 4-foreign-label label crd "$CRD" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
  fi
  crd_meta "4-$mode-protected" | tee -a "${RUN_DIR}/4-$mode.txt"
  CASCADE="${CASCADE:-background}"   # background (default) | orphan: orphan makes GC drop ownerReferences instead of deleting dependents
  echo "-- deleting the extension with --cascade=$CASCADE" | tee -a "${RUN_DIR}/4-$mode.txt"
  record "4-$mode-$CASCADE-delete-ce" delete clusterextension "$CE" --cascade="$CASCADE" --timeout=300s >/dev/null || true
  wait_for 300 "extension gone" absent clusterextension "$CE" || true
  sleep 10
  echo "-- after deletion:" | tee -a "${RUN_DIR}/4-$mode.txt"
  crd_meta "4-$mode-after" | tee -a "${RUN_DIR}/4-$mode.txt"
  if absent crd "$CRD"; then outcome "0002-4-$mode-$CASCADE" OBSERVED "CRD deleted despite $mode (cascade=$CASCADE)"; else outcome "0002-4-$mode-$CASCADE" OBSERVED "CRD SURVIVED with $mode (cascade=$CASCADE); CRs: $(k get nodehealthchecks -o name 2>/dev/null | wc -l | tr -d ' ')"; fi
  ;;
5)
  echo "== 0002-5 adopt: install a fresh NHC ClusterExtension over the surviving, unowned CRD"
  expect "CRD present and unowned by any extension" bash -c "$(declare -f k); k get crd $CRD -o json | python3 -c 'import json,sys; m=json.load(sys.stdin)[\"metadata\"]; sys.exit(1 if any(k.startswith(\"olm.operatorframework.io/\") for k in m.get(\"labels\",{})) else 0)'" || true
  crd_meta 5-before | tee "${RUN_DIR}/5-adopt.txt"
  record 5-install apply -f "$(dirname "$0")/rbac/nhc/30-clusterextension.yaml" >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 15; s=$(ce_condition "$CE" Installed); echo "t+$((i*15))s Installed=$s"; [ "$s" = "True/Succeeded" ] && break; done
  ce_msg "$CE" | tee -a "${RUN_DIR}/5-adopt.txt"
  crd_meta 5-after | tee -a "${RUN_DIR}/5-adopt.txt"
  if ce_installed "$CE"; then outcome 0002-5 OBSERVED "fresh extension installed over existing CRD; CRs: $(k get nodehealthchecks -o name 2>/dev/null | wc -l | tr -d ' ')"; else outcome 0002-5 OBSERVED "fresh extension did NOT install over existing CRD"; fi
  ;;
6)
  echo "== 0002-6 verify CR identity and admission after adoption"
  crd_meta 6-verify | tee "${RUN_DIR}/6-verify.txt"
  expect "exp0002-a exists" found nodehealthcheck exp0002-a
  expect "exp0002-b exists" found nodehealthcheck exp0002-b
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" nhc --quick | tee -a "${RUN_DIR}/6-verify.txt"
  outcome 0002-6 DONE "see 6-verify.txt"
  ;;
cleanup)
  record c-delete-crs delete nodehealthcheck exp0002-a exp0002-b --ignore-not-found >/dev/null || true
  absent clusterextension nhc-second || record c-delete-second delete clusterextension nhc-second --ignore-not-found >/dev/null || true
  echo "cleaned test CRs; NHC extension left as is"
  ;;
*) echo "unknown step $step" >&2; exit 2 ;;
esac
