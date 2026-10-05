#!/usr/bin/env bash
# test/olmv1/exp0003.sh STEP — experiment 0003: six RHWA operators installed via ClusterExtension hand
# their twelve CRDs (and the CRs in them) to the WAO bundle, which owns the same CRDs under its own
# release. Uses the release-and-adopt sequence from experiment 0002. Run one step at a time, in order.
# Destructive to the six test installs (disposable cluster); never touches nodes directly. SNR's node
# agents keep running throughout (their DaemonSet is owned by the SNR Config, not by any extension).
EXP="${EXP:-0003}" source "$(dirname "$0")/lib.sh"   # EXP=0004 for the 5.0 re-run; the run dir follows it
WAO_CE=workload-availability-operator
WAO_RELEASE_NS="$NS"
ALL_CRDS="$(for k in nhc snr far mdr nmo sbr; do op_crds "$k"; done | tr ' ' '\n')"
step="${1:?step number}"

crd_uids() { k get crd -o json | python3 -c '
import json,sys
for c in json.load(sys.stdin)["items"]:
    if "medik8s" in c["metadata"]["name"]:
        m=c["metadata"]; print(m["name"], m["uid"], m.get("labels",{}).get("olm.operatorframework.io/owner-name","-"), "ownerRef" if m.get("ownerReferences") else "no-ownerRef")'; }
cr_uids() {
  for r in nodehealthchecks fenceagentsremediationtemplates selfnoderemediationtemplates machinedeletionremediationtemplates selfnoderemediationconfigs; do
    k get "$r" -A -o custom-columns="KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid" 2>/dev/null | grep -v '^KIND' || true
  done
}
old_objects() {  # old_objects KEY : everything still labeled with the old extension's owner name
  local pkg; pkg=$(op_package "$1")
  k get all,sa,secret,configmap,role,rolebinding -A -l "olm.operatorframework.io/owner-name=$pkg" -o name 2>/dev/null
  k get validatingwebhookconfigurations,mutatingwebhookconfigurations,clusterrole,clusterrolebinding -l "olm.operatorframework.io/owner-name=$pkg" -o name 2>/dev/null
  return 0
}

case "$step" in
1)
  echo "== 0003-1 baseline: inert test CRs in four CRDs, record all CRD UIDs and owners"
  for k in nhc snr far mdr nmo sbr; do expect "$(op_package "$k") installed" ce_installed "$(op_package "$k")"; done
  sed 's/name: exp0001-nhc/name: exp0003-nhc/' "$(dirname "$0")/samples/nhc-valid.yaml" | record 1-create-nhc create -f - >/dev/null
  sed 's/name: exp0001-/name: exp0003-/' "$(dirname "$0")/samples/fartemplate-valid.yaml" | record 1-create-fartemplate create -f - >/dev/null
  sed 's/name: exp0001-/name: exp0003-/' "$(dirname "$0")/samples/snrtemplate-valid.yaml" | record 1-create-snrtemplate create -f - >/dev/null
  sed 's/name: exp0001-/name: exp0003-/' "$(dirname "$0")/samples/mdrtemplate-valid.yaml" | record 1-create-mdrtemplate create -f - >/dev/null
  { echo "-- CRDs:"; crd_uids; echo "-- CRs (incl. SNR's own default config and templates):"; cr_uids; echo "-- SNR agents:"; k get ds -n "$NS" -o custom-columns='NAME:.metadata.name,READY:.status.numberReady'; } | tee "${RUN_DIR}/1-baseline.txt"
  for k in nhc snr far mdr nmo sbr; do record "1-old-objects-$k" get all,sa,configmap,role,rolebinding -A -l "olm.operatorframework.io/owner-name=$(op_package "$k")" -o json >/dev/null; done
  snapshot 1
  outcome 0003-1 PASS "baseline recorded"
  ;;
2)
  echo "== 0003-2 orphan-delete the six extensions (SNR last); CRDs, CRs and all rendered objects must survive"
  for k in nhc nmo mdr far sbr snr; do
    pkg=$(op_package "$k")
    record "2-$k-orphan-delete" delete clusterextension "$pkg" --cascade=orphan --timeout=300s >/dev/null
    wait_for 300 "$pkg gone" absent clusterextension "$pkg"
    for crd in $(op_crds "$k"); do expect "CRD $crd survived" found crd "$crd"; done
  done
  { echo "-- CRDs after orphan delete:"; crd_uids; echo "-- CRs:"; cr_uids; echo "-- old manager pods still running:"; k get pods -n "$NS" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'; } | tee "${RUN_DIR}/2-after-orphan.txt"
  snapshot 2
  outcome 0003-2 PASS "six extensions deleted with --cascade=orphan; CRDs survived"
  ;;
3)
  echo "== 0003-3 stop the old authorities: delete orphaned managers, webhooks, services, RBAC by owner-name label (CRDs kept)"
  for k in nhc nmo mdr far sbr snr; do
    pkg=$(op_package "$k")
    echo "-- $pkg"
    # Order: webhook configurations first (their backends are about to go), then workloads, then RBAC/SA/secrets.
    for w in $(k get validatingwebhookconfigurations,mutatingwebhookconfigurations -l "olm.operatorframework.io/owner-name=$pkg" -o name); do record "3-$k-del-$(basename $w)" delete "$w" --ignore-not-found >/dev/null; done
    for d in $(k get deployment -n "$NS" -l "olm.operatorframework.io/owner-name=$pkg" -o name); do record "3-$k-del-$(basename $d)" delete "$d" -n "$NS" --ignore-not-found >/dev/null; done
    for o in $(k get service,configmap,secret,sa,role,rolebinding -n "$NS" -l "olm.operatorframework.io/owner-name=$pkg" -o name); do record "3-$k-del-$(echo $o | tr '/' '-')" delete "$o" -n "$NS" --ignore-not-found >/dev/null; done
    for o in $(k get clusterrole,clusterrolebinding -l "olm.operatorframework.io/owner-name=$pkg" -o name); do record "3-$k-del-$(echo $o | tr '/' '-')" delete "$o" --ignore-not-found >/dev/null; done
    left=$( { old_objects "$k" | grep -v customresourcedefinition || true; } | wc -l | tr -d ' ')
    echo "   remaining non-CRD objects labeled $pkg: $left"
    for crd in $(op_crds "$k"); do expect "CRD $crd still present" found crd "$crd"; done
  done
  wait_for 120 "no old manager pods remain" bash -c "$(declare -f k); export NS='$NS'; [ -z \"\$(k get pods -n $NS -o name | grep -v self-node-remediation-ds)\" ]"
  { echo "-- pods in $NS (expect only SNR agents):"; k get pods -n "$NS" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'; echo "-- CRs:"; cr_uids; echo "-- medik8s webhook configurations left:"; k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -c -i -E 'kb.io|medik8s' || true; } | tee "${RUN_DIR}/3-stopped.txt"
  snapshot 3
  outcome 0003-3 PASS "old authorities stopped; CRDs and CRs intact"
  ;;
4)
  echo "== 0003-4 re-annotate the twelve CRDs for adoption by the WAO release"
  for crd in $ALL_CRDS; do
    record "4-annotate-$crd" annotate crd "$crd" "meta.helm.sh/release-name=$WAO_CE" "meta.helm.sh/release-namespace=$WAO_RELEASE_NS" --overwrite >/dev/null
    record "4-label-$crd" label crd "$crd" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
  done
  { echo "-- CRDs re-annotated:"; k get crd -o json | python3 -c '
import json,sys
for c in json.load(sys.stdin)["items"]:
    if "medik8s" in c["metadata"]["name"]:
        a=c["metadata"].get("annotations",{}); print(c["metadata"]["name"], a.get("meta.helm.sh/release-name"), a.get("meta.helm.sh/release-namespace"))'; } | tee "${RUN_DIR}/4-reannotated.txt"
  outcome 0003-4 PASS "twelve CRDs annotated for release $WAO_CE"
  ;;
5)
  echo "== 0003-5 install the WAO ClusterExtension over the re-annotated CRDs"
  rbac_dir="$(dirname "$0")/rbac/wao"
  [ -d "$rbac_dir" ] || { echo "missing $rbac_dir" >&2; exit 2; }
  if [ "${SKIP_INSTALLER_RBAC:-0}" = 1 ]; then
    echo "SKIP_INSTALLER_RBAC=1: no installer SA/ClusterRole applied; spec.serviceAccount stripped from the ClusterExtension"
  else
    for f in 00-serviceaccount 10-clusterrole 20-clusterrolebinding; do record "5-apply-$f" apply -f "$rbac_dir/$f.yaml" >/dev/null; done
  fi
  apply_ce 5-apply-ce "$rbac_dir/30-clusterextension.yaml" >/dev/null
  start=$(date +%s)
  while ! ce_installed "$WAO_CE"; do
    msg=$(k get clusterextension "$WAO_CE" -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}: {.message}{end}' 2>/dev/null | cut -c1-300)
    echo "t+$(( $(date +%s) - start ))s $msg"
    if echo "$msg" | grep -q 'forbidden\|cannot be managed'; then record 5-ce-status-failed get clusterextension "$WAO_CE" -o json >/dev/null; outcome 0003-5 FAIL "$msg"; exit 3; fi
    if (( $(date +%s) - start > 600 )); then outcome 0003-5 FAIL "timeout"; exit 1; fi
    sleep 15
  done
  { k get clusterextension "$WAO_CE" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' | cut -c1-200; echo "-- CRDs now:"; crd_uids; echo "-- CRs:"; cr_uids; } | tee "${RUN_DIR}/5-installed.txt"
  wait_for 300 "WAO manager available" deployment_available workload-availability-operator-controller-manager
  wait_for 120 "WAO default config exists" found workloadavailabilityconfig cluster
  snapshot 5
  outcome 0003-5 PASS "WAO installed and adopted the CRDs"
  ;;
6)
  echo "== 0003-6 enable NHC then SNR through WAO; preserved CRs must be reconciled by the new operands"
  for comp in nodeHealthCheck selfNodeRemediation; do
    record "6-enable-$comp" patch workloadavailabilityconfig cluster --type merge -p "{\"spec\":{\"components\":{\"$comp\":{\"state\":\"Enabled\"}}}}" >/dev/null
  done
  wait_for 300 "NHC operand available" deployment_available node-healthcheck-controller-manager
  wait_for 300 "SNR operand available" deployment_available self-node-remediation-controller-manager
  # WAO renders webhook configurations under the bundle names, not operator-controller's *.kb.io names.
  wait_for 180 "NHC webhook CA injected" ca_injected validatingwebhookconfiguration/node-healthcheck-validating-webhook-configuration
  wait_for 180 "SNR webhook CA injected" ca_injected validatingwebhookconfiguration/self-node-remediation-validating-webhook-configuration
  { k get workloadavailabilityconfig cluster -o jsonpath='{range .status.components[*]}{.name} phase={.phase} admissionReady={.admissionReady}{"\n"}{end}'; echo "-- CRs:"; cr_uids; echo "-- SNR agents:"; k get ds -n "$NS" -o custom-columns='NAME:.metadata.name,READY:.status.numberReady'; } | tee "${RUN_DIR}/6-enabled.txt"
  snapshot 6
  outcome 0003-6 PASS "NHC and SNR operands running under WAO"
  ;;
7)
  echo "== 0003-7 verify identities and admission"
  { echo "-- CRDs:"; crd_uids; echo "-- CRs:"; cr_uids; } | tee "${RUN_DIR}/7-verify.txt"
  # Compare the twelve component CRDs only (the WAO config CRD is new by design).
  diff <(grep -E '\.medik8s\.io ' "${RUN_DIR}/1-baseline.txt" | grep -v workloadavailability | awk '{print $1, $2}' | sort) <(crd_uids | grep -v workloadavailability | awk '{print $1, $2}' | sort) && echo "PASS: all twelve CRD UIDs unchanged since baseline" || echo "FAIL: CRD UID drift" >&2
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" nhc --quick | tee -a "${RUN_DIR}/7-verify.txt"
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" snr --quick | tee -a "${RUN_DIR}/7-verify.txt"
  outcome 0003-7 DONE "see 7-verify.txt"
  ;;
*) echo "unknown step $step" >&2; exit 2 ;;
esac
