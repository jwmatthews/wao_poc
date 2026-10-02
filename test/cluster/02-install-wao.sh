#!/usr/bin/env bash
# test/cluster/02-install-wao.sh — WAO-INST-02: install WAO through OLM with a manually approved InstallPlan.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-02 install"
record 02-namespace apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  annotations:
    openshift.io/node-selector: ""
YAML
record 02-operatorgroup apply -f - >/dev/null <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: wao
  namespace: ${NS}
spec: {}
YAML
record 02-subscription apply -f - >/dev/null <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${NS}
spec:
  channel: ${CHANNEL}
  name: ${PACKAGE}
  source: ${CATALOG}
  sourceNamespace: ${CAT_NS}
  installPlanApproval: Manual
YAML

installplan_ref() { k get subscription "$PACKAGE" -n "$NS" -o jsonpath='{.status.installPlanRef.name}'; }
has_installplan() { local ip; ip=$(installplan_ref) || return 1; [ -n "$ip" ]; }
wait_for 180 "InstallPlan created" has_installplan
ip=$(installplan_ref)
record 02-installplan get installplan "$ip" -n "$NS" -o json >/dev/null
csv=$(k get installplan "$ip" -n "$NS" -o jsonpath='{.spec.clusterServiceVersionNames[0]}')
expect "InstallPlan installs $CSV_NAME" test "$csv" = "$CSV_NAME"
record 02-approve patch installplan "$ip" -n "$NS" --type merge -p '{"spec":{"approved":true}}' >/dev/null

csv_succeeded() { local p; p=$(k get csv "$CSV_NAME" -n "$NS" -o jsonpath='{.status.phase}') || return 1; [ "$p" = Succeeded ]; }
wait_for 300 "CSV $CSV_NAME Succeeded" csv_succeeded
wait_for 180 "WAO Deployment Available" deployment_available "$WAO_DEPLOYMENT"
expect "exactly one Deployment (the WAO controller)" only_wao_deployment
expect "all thirteen CRDs exist" crds_present "$ALL_CRDS"
expect "the CSV owns all thirteen CRDs" jcheck \
  'len({c["name"] for c in o["spec"]["customresourcedefinitions"]["owned"]}) == 13' get csv "$CSV_NAME" -n "$NS"
snapshot 02
