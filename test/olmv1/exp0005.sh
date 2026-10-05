#!/usr/bin/env bash
# test/olmv1/exp0005.sh STEP — experiment 0005: six RHWA operators installed through OLM Classic
# Subscriptions hand their twelve CRDs (and the CRs in them) to the WAO ClusterExtension. Classic never
# deletes CRDs on uninstall, so the release step is "delete Subscription and CSV"; adoption is the same
# Helm-annotation mechanism as exp0003. Run one step at a time, in order, on a disposable cluster that
# ships both OLM generations (OCP 5.0). Never touches nodes directly; SNR's agents keep running throughout.
#
# Env: CLASSIC_NS   namespace the Subscriptions go in (default openshift-operators, the global OperatorGroup;
#                   set openshift-workload-availability for the docs-recommended variant, an OperatorGroup is
#                   created there if missing)
#      NS           WAO's install namespace (lib default openshift-workload-availability)
#      CATALOG_SOURCE  Classic CatalogSource name (default redhat-operators)
#      SKIP_INSTALLER_RBAC=1 on 5.0 (spec.serviceAccount is ignored there)
EXP="${EXP:-0005}" source "$(dirname "$0")/lib.sh"
CLASSIC_NS="${CLASSIC_NS:-openshift-operators}"
CATALOG_SOURCE="${CATALOG_SOURCE:-redhat-operators}"
WAO_CE=workload-availability-operator
WAO_RELEASE_NS="$NS"
ALL_CRDS="$(for k in $OPERATORS; do op_crds "$k"; done | tr ' ' '\n')"
step="${1:?step number}"

csv_name() { echo "$(op_package "$1").v$(op_version "$1")"; }
csv_phase() { k get csv "$1" -n "$CLASSIC_NS" -o jsonpath='{.status.phase}' 2>/dev/null; }
csv_succeeded() { [ "$(csv_phase "$1")" = Succeeded ]; }
crd_uids() { k get crd -o json | python3 -c '
import json,sys
for c in json.load(sys.stdin)["items"]:
    if "medik8s" in c["metadata"]["name"]:
        m=c["metadata"]; l=m.get("labels",{})
        print(m["name"], m["uid"], l.get("olm.operatorframework.io/owner-name","-"), "olm.managed" if l.get("olm.managed") else "-", "ownerRef" if m.get("ownerReferences") else "no-ownerRef")'; }
cr_uids() {
  for r in nodehealthchecks fenceagentsremediationtemplates selfnoderemediationtemplates machinedeletionremediationtemplates selfnoderemediationconfigs; do
    k get "$r" -A -o custom-columns="KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid" 2>/dev/null | grep -v '^KIND' || true
  done
}
snr_inventory() {
  echo "-- SelfNodeRemediationConfigs (all namespaces):"; k get selfnoderemediationconfig -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid' 2>/dev/null || true
  echo "-- SNR DaemonSets (all namespaces):"; k get ds -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.numberReady,OWNER:.metadata.ownerReferences[0].kind,IMAGE:.spec.template.spec.containers[0].image' | grep -E '^NS|self-node' || true
}
medik8s_webhooks() { k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -c -i -E 'kb.io|medik8s|remediation|maintenance|healthcheck' || true; }

case "$step" in
1)
  echo "== 0005-1 reset: remove the WAO ClusterExtension (deletes its CRDs and CRs) so the cluster has no RHWA"
  if found clusterextension "$WAO_CE" 2>/dev/null; then
    record 1-delete-wao-ce delete clusterextension "$WAO_CE" --timeout=300s >/dev/null
    wait_for 300 "WAO extension gone" absent clusterextension "$WAO_CE"
  fi
  for k in nhc nmo mdr far sbr snr; do if found clusterextension "$(op_package "$k")" 2>/dev/null; then record "1-delete-$k-ce" delete clusterextension "$(op_package "$k")" --timeout=300s >/dev/null; fi; done
  # P43: OLM GC deletes WAO's manager together with its CRDs, so the config CR's own finalizer is never
  # cleared and the config CRD plus every operand owned by the CR stay behind. Clear it by hand (recorded).
  sleep 20
  if k get workloadavailabilityconfig cluster -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    echo "P43: WorkloadAvailabilityConfig/cluster stuck terminating on its finalizer; clearing it by hand"
    record 1-waoconfig-stuck get workloadavailabilityconfig cluster -o json >/dev/null || true
    record 1-clear-finalizer patch workloadavailabilityconfig cluster --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || true
  fi
  wait_for 300 "no medik8s CRDs" bash -c "$(declare -f k); [ \"\$(k get crd -o name | grep -c medik8s || true)\" = 0 ]"
  record 1-delete-nhc-aggregation delete clusterrole,clusterrolebinding node-healthcheck-operator-aggregation --ignore-not-found >/dev/null || true
  wait_for 300 "no manager pods in $NS" bash -c "$(declare -f k); [ -z \"\$(k get pods -n $NS -o name 2>/dev/null)\" ]"
  expect "no medik8s webhook configurations" bash -c "$(declare -f k medik8s_webhooks); [ \"\$(medik8s_webhooks)\" = 0 ]"
  expect "no RHWA Subscription in $CLASSIC_NS" bash -c "$(declare -f k); [ \"\$(k get sub -n $CLASSIC_NS -o name | grep -c -E 'remediation|healthcheck|maintenance' || true)\" = 0 ]"
  snapshot 1
  outcome 0005-1 PASS "clean of RHWA; ClusterCatalog wao-poc and build namespace kept"
  ;;
2)
  echo "== 0005-2 Classic install: six Subscriptions in $CLASSIC_NS from CatalogSource $CATALOG_SOURCE (NHC first, SNR last)"
  if ! found namespace "$CLASSIC_NS" 2>/dev/null; then record 2-create-ns create namespace "$CLASSIC_NS" >/dev/null; fi
  if [ -z "$(k get operatorgroup -n "$CLASSIC_NS" -o name)" ]; then
    printf 'apiVersion: operators.coreos.com/v1\nkind: OperatorGroup\nmetadata:\n  name: rhwa-all-namespaces\n  namespace: %s\nspec: {}\n' "$CLASSIC_NS" | record 2-create-og apply -f - >/dev/null
  fi
  record 2-og get operatorgroup -n "$CLASSIC_NS" -o json >/dev/null
  for key in $OPERATORS; do
    pkg=$(op_package "$key"); csv=$(csv_name "$key")
    printf 'apiVersion: operators.coreos.com/v1alpha1\nkind: Subscription\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  name: %s\n  channel: %s\n  source: %s\n  sourceNamespace: openshift-marketplace\n  installPlanApproval: Automatic\n  startingCSV: %s\n' \
      "$pkg" "$CLASSIC_NS" "$pkg" "$CHANNEL" "$CATALOG_SOURCE" "$csv" | tee "${RUN_DIR}/raw/2-sub-$key.yaml" | record "2-$key-apply-sub" apply -f - >/dev/null
    start=$(date +%s)
    until csv_succeeded "$csv"; do
      if (( $(date +%s) - start > 600 )); then
        echo "FAIL: CSV $csv phase=$(csv_phase "$csv") after 600s" >&2
        record "2-$key-csv-failed" get csv "$csv" -n "$CLASSIC_NS" -o json >/dev/null || true
        record "2-$key-sub-failed" get sub "$pkg" -n "$CLASSIC_NS" -o json >/dev/null || true
        outcome "0005-2-$key" FAIL "CSV not Succeeded in 600s"; exit 1
      fi
      sleep 10
    done
    echo "ok: CSV $csv Succeeded ($(( $(date +%s) - start ))s)"
    for crd in $(op_crds "$key"); do expect "CRD $crd established" crd_established "$crd"; done
    expect "manager $(op_deployment "$key") available in $CLASSIC_NS" bash -c "$(declare -f k); start=\$(date +%s); until k wait deployment/$(op_deployment "$key") -n $CLASSIC_NS --for=condition=Available --timeout=10s >/dev/null 2>&1; do [ \$(( \$(date +%s) - start )) -gt 300 ] && exit 1; sleep 5; done"
    record "2-$key-csv" get csv "$csv" -n "$CLASSIC_NS" -o json >/dev/null
    record "2-$key-deploy" get deployment "$(op_deployment "$key")" -n "$CLASSIC_NS" -o json >/dev/null
    outcome "0005-2-$key" PASS "CSV Succeeded, CRDs established, manager available"
  done
  { echo "-- CSVs:"; k get csv -n "$CLASSIC_NS" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,VERSION:.spec.version'; echo "-- CRDs (labels/owners under Classic):"; crd_uids; echo "-- webhook configurations:"; k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o custom-columns='KIND:.kind,NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind,OLM-OWNER:.metadata.labels.olm\.owner'; } | tee "${RUN_DIR}/2-classic-installed.txt"
  record 2-webhooks get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >/dev/null
  record 2-crds get crd -o json >/dev/null
  record 2-installplans get installplan -n "$CLASSIC_NS" -o json >/dev/null
  outcome 0005-2 PASS "six operators installed through Classic in $CLASSIC_NS"
  ;;
3)
  echo "== 0005-3 webhook matrix under Classic (control), NS=$CLASSIC_NS"
  for key in nhc nmo far snr; do NS="$CLASSIC_NS" RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" "$key" | tee -a "${RUN_DIR}/3-classic-webhooks.txt" | grep -E '^summary'; done
  outcome 0005-3 DONE "see 3-classic-webhooks.txt"
  ;;
4)
  echo "== 0005-4 baseline: inert test CRs in $CLASSIC_NS, record CRD and CR UIDs"
  # Samples hard-code namespace openshift-workload-availability; rewrite it to CLASSIC_NS so the test
  # CRs live where a Classic customer's would (the NHC's remediationTemplate reference included).
  sed -e 's/name: exp0001-nhc/name: exp0005-nhc/' -e "s/namespace: .*/namespace: $CLASSIC_NS/" "$(dirname "$0")/samples/nhc-valid.yaml" | tee "${RUN_DIR}/raw/4-nhc.yaml" | record 4-create-nhc create -f - >/dev/null
  for s in fartemplate-valid snrtemplate-valid mdrtemplate-valid; do
    sed -e 's/name: exp0001-/name: exp0005-/' -e "s/namespace: .*/namespace: $CLASSIC_NS/" "$(dirname "$0")/samples/$s.yaml" | tee "${RUN_DIR}/raw/4-$s.yaml" | record "4-create-$s" create -f - >/dev/null
  done
  { echo "-- CRDs:"; crd_uids; echo "-- CRs:"; cr_uids; snr_inventory; } | tee "${RUN_DIR}/4-baseline.txt"
  snapshot 4
  outcome 0005-4 PASS "baseline recorded"
  ;;
5)
  echo "== 0005-5 Classic uninstall: delete Subscription then CSV for each operator (SNR last); CRDs and CRs must survive"
  t0=$(date +%s)
  for key in $OPERATORS; do
    pkg=$(op_package "$key"); csv=$(csv_name "$key")
    record "5-$key-delete-sub" delete subscription "$pkg" -n "$CLASSIC_NS" --ignore-not-found >/dev/null
    record "5-$key-delete-csv" delete csv "$csv" -n "$CLASSIC_NS" --ignore-not-found --timeout=300s >/dev/null
    wait_for 300 "CSV $csv gone" absent csv "$csv" -n "$CLASSIC_NS"
    for crd in $(op_crds "$key"); do expect "CRD $crd survived Classic uninstall" found crd "$crd"; done
  done
  wait_for 300 "no manager pods left in $CLASSIC_NS" bash -c "$(declare -f k); [ -z \"\$(k get pods -n $CLASSIC_NS -o name | grep -E 'remediation|healthcheck|maintenance' | grep -v self-node-remediation-ds)\" ]"
  echo "managers gone $(( $(date +%s) - t0 ))s after the first deletion"
  { echo "-- CRDs after Classic uninstall:"; crd_uids; echo "-- CRs:"; cr_uids; snr_inventory; echo "-- medik8s webhook configurations left: $(medik8s_webhooks)"; echo "-- Classic leftovers in $CLASSIC_NS:"; k get installplan,operatorcondition,sa,role,rolebinding,service,secret -n "$CLASSIC_NS" -o name | grep -E 'remediation|healthcheck|maintenance' || echo "(none)"; echo "-- Operator objects (operators.coreos.com):"; k get operators.operators.coreos.com -o name | grep -E 'remediation|healthcheck|maintenance' || echo "(none)"; } | tee "${RUN_DIR}/5-after-uninstall.txt"
  snapshot 5
  outcome 0005-5 PASS "Classic uninstalled; CRDs survived"
  ;;
6)
  echo "== 0005-6 annotate the twelve CRDs for adoption by the WAO release (Classic labels left in place)"
  for crd in $ALL_CRDS; do
    record "6-annotate-$crd" annotate crd "$crd" "meta.helm.sh/release-name=$WAO_CE" "meta.helm.sh/release-namespace=$WAO_RELEASE_NS" --overwrite >/dev/null
    record "6-label-$crd" label crd "$crd" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
  done
  { echo "-- CRDs re-annotated:"; k get crd -o json | python3 -c '
import json,sys
for c in json.load(sys.stdin)["items"]:
    if "medik8s" in c["metadata"]["name"]:
        a=c["metadata"].get("annotations",{}); l=c["metadata"].get("labels",{})
        print(c["metadata"]["name"], a.get("meta.helm.sh/release-name"), a.get("meta.helm.sh/release-namespace"), "olm.managed=" + str(l.get("olm.managed")))'; } | tee "${RUN_DIR}/6-reannotated.txt"
  outcome 0005-6 PASS "twelve CRDs annotated for release $WAO_CE"
  ;;
7)
  echo "== 0005-7 install the WAO ClusterExtension over the Classic-created CRDs"
  rbac_dir="$(dirname "$0")/rbac/wao"
  if [ "${SKIP_INSTALLER_RBAC:-0}" = 1 ]; then
    echo "SKIP_INSTALLER_RBAC=1: no installer SA/ClusterRole applied; spec.serviceAccount stripped from the ClusterExtension"
  else
    for f in 00-serviceaccount 10-clusterrole 20-clusterrolebinding; do record "7-apply-$f" apply -f "$rbac_dir/$f.yaml" >/dev/null; done
  fi
  apply_ce 7-apply-ce "$rbac_dir/30-clusterextension.yaml" >/dev/null
  start=$(date +%s)
  while ! ce_installed "$WAO_CE"; do
    msg=$(k get clusterextension "$WAO_CE" -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}: {.message}{end}' 2>/dev/null | cut -c1-300)
    echo "t+$(( $(date +%s) - start ))s $msg"
    if echo "$msg" | grep -q 'forbidden\|cannot be managed'; then record 7-ce-status-failed get clusterextension "$WAO_CE" -o json >/dev/null; outcome 0005-7 FAIL "$msg"; exit 3; fi
    if (( $(date +%s) - start > 600 )); then outcome 0005-7 FAIL "timeout"; exit 1; fi
    sleep 15
  done
  { k get clusterextension "$WAO_CE" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' | cut -c1-200; echo "-- CRDs now:"; crd_uids; echo "-- CRs:"; cr_uids; } | tee "${RUN_DIR}/7-installed.txt"
  wait_for 300 "WAO manager available" deployment_available workload-availability-operator-controller-manager
  wait_for 120 "WAO default config exists" found workloadavailabilityconfig cluster
  snapshot 7
  outcome 0005-7 PASS "WAO installed and adopted the CRDs"
  ;;
8)
  echo "== 0005-8 enable NHC then SNR through WAO; verify UIDs, admission, and the SNR namespace question"
  for comp in nodeHealthCheck selfNodeRemediation; do
    record "8-enable-$comp" patch workloadavailabilityconfig cluster --type merge -p "{\"spec\":{\"components\":{\"$comp\":{\"state\":\"Enabled\"}}}}" >/dev/null
  done
  wait_for 300 "NHC operand available" deployment_available node-healthcheck-controller-manager
  wait_for 300 "SNR operand available" deployment_available self-node-remediation-controller-manager
  wait_for 180 "NHC webhook CA injected" ca_injected validatingwebhookconfiguration/node-healthcheck-validating-webhook-configuration
  wait_for 180 "SNR webhook CA injected" ca_injected validatingwebhookconfiguration/self-node-remediation-validating-webhook-configuration
  sleep 60   # give WAO's SNR operand time to create a default config in $NS if it does not see the old one
  { k get workloadavailabilityconfig cluster -o jsonpath='{range .status.components[*]}{.name} phase={.phase} admissionReady={.admissionReady}{"\n"}{end}'; echo "-- CRDs:"; crd_uids; echo "-- CRs:"; cr_uids; snr_inventory; } | tee "${RUN_DIR}/8-enabled.txt"
  base=$(grep -E '\.medik8s\.io ' "${RUN_DIR}/4-baseline.txt" | grep -v workloadavailability | awk '{print $1, $2}' | sort)
  now=$(crd_uids | grep -v workloadavailability | awk '{print $1, $2}' | sort)
  if diff <(echo "$base") <(echo "$now" | grep -F -f <(echo "$base" | awk '{print $1}')) >/dev/null; then echo "PASS: all $(echo "$base" | wc -l | tr -d ' ') baseline CRD UIDs unchanged"; else echo "FAIL: CRD UID drift" >&2; diff <(echo "$base") <(echo "$now") || true; fi
  echo "CRDs created new by WAO (not at baseline): $(comm -13 <(echo "$base" | awk '{print $1}') <(echo "$now" | awk '{print $1}') | tr '\n' ' ')"
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" nhc --quick | tee -a "${RUN_DIR}/8-enabled.txt"
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" snr --quick | tee -a "${RUN_DIR}/8-enabled.txt"
  if [ "$CLASSIC_NS" != "$NS" ]; then
    echo "-- namespace check: can an NHC reference a template that lives in $CLASSIC_NS? (dry-run)"
    sed -e 's/name: exp0001-nhc/name: exp0005-nhc-xns/' -e "s/namespace: .*/namespace: $CLASSIC_NS/" "$(dirname "$0")/samples/nhc-valid.yaml" | record 8-nhc-xns-dryrun create --dry-run=server -f - || true
  fi
  snapshot 8
  outcome 0005-8 DONE "see 8-enabled.txt (SNR inventory answers the namespace question)"
  ;;
9)
  echo "== 0005-9 enable FAR, MDR, NMO, SBR"
  for comp in fenceAgentsRemediation machineDeletionRemediation nodeMaintenance storageBasedRemediation; do
    record "9-enable-$comp" patch workloadavailabilityconfig cluster --type merge -p "{\"spec\":{\"components\":{\"$comp\":{\"state\":\"Enabled\"}}}}" >/dev/null
  done
  wait_for 300 "FAR operand available" deployment_available fence-agents-remediation-controller-manager || true
  wait_for 300 "NMO operand available" deployment_available node-maintenance-operator-controller-manager || true
  wait_for 300 "SBR operand available" deployment_available sbr-operator-controller-manager || true
  wait_for 120 "MDR operand available" deployment_available machine-deletion-remediation-controller-manager || echo "MDR not available (P30)"
  { k get workloadavailabilityconfig cluster -o jsonpath='{range .status.components[*]}{.name} phase={.phase} admissionReady={.admissionReady}{"\n"}{end}'; k get pods -n "$NS" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase'; } | tee "${RUN_DIR}/9-enable-rest.txt"
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" far --quick | tee -a "${RUN_DIR}/9-enable-rest.txt"
  RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" nmo --quick | tee -a "${RUN_DIR}/9-enable-rest.txt"
  outcome 0005-9 DONE "see 9-enable-rest.txt"
  ;;
*) echo "unknown step $step" >&2; exit 2 ;;
esac
