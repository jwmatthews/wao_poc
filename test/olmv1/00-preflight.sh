#!/usr/bin/env bash
# test/olmv1/00-preflight.sh — experiment 0001 preflight. Read-only.
# Confirms the cluster is 4.22 with OLM v1 serving the Red Hat catalog, has no RHWA operators or
# CRDs, and records the baseline. Fails before anything is written if a precondition is missing.
source "$(dirname "$0")/lib.sh"
echo "== 0001-00 preflight (read-only) on $(k whoami --show-server 2>/dev/null | sed 's#https://##' | cut -d. -f1-2)"

record 00-version get clusterversion version -o jsonpath='{.status.desired.version}' >/dev/null
ver=$(k get clusterversion version -o jsonpath='{.status.desired.version}')
glob="${OCP_VERSION_GLOB:-4.22.*}"   # set OCP_VERSION_GLOB='5.0.*' for the 5.0 re-run (experiment 0004)
expect "cluster version matches $glob (got $ver)" bash -c "case '$ver' in $glob) exit 0;; *) exit 1;; esac"

expect "operator-controller is available" k wait deployment/operator-controller-controller-manager \
  -n openshift-operator-controller --for=condition=Available --timeout=10s
expect "ClusterCatalog $CATALOG_NAME is serving" jcheck 'any(c["type"]=="Serving" and c["status"]=="True" for c in o["status"]["conditions"])' get clustercatalog "$CATALOG_NAME"

expect "no ClusterExtension exists" bash -c 'out=$(k get clusterextension -o name) && [ -z "$out" ]'
expect "no medik8s CRD exists" bash -c 'out=$(k get crd -o name | grep -c medik8s || true); [ "$out" = 0 ]'
expect "no RHWA CSV exists anywhere" bash -c 'out=$(k get csv -A -o name | grep -E -c "health|remediation|maintenance" || true); [ "$out" = 0 ]'
expect "install namespace $NS is absent" absent namespace "$NS"
expect "no medik8s webhook configurations exist" bash -c 'out=$(k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -c medik8s || true); [ "$out" = 0 ]'

record 00-nodes get nodes -o wide >/dev/null
record 00-nodes-labels get nodes -o json >/dev/null
record 00-clustercatalogs get clustercatalog -o json >/dev/null
record 00-operator-controller get deployment -n openshift-operator-controller -o json >/dev/null
record 00-catalogd get deployment -n openshift-catalogd -o json >/dev/null
echo "operator-controller image: $(k get deployment operator-controller-controller-manager -n openshift-operator-controller -o jsonpath='{.spec.template.spec.containers[0].image}')"
nodes=$(k get nodes -o name | wc -l | tr -d ' ')
cp=$(k get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l | tr -d ' ')
echo "nodes: $nodes, of which control-plane: $cp (every node reboot in this experiment hits a control-plane node)"
outcome 0001-00 PASS "$ver, OLM v1 serving, clean of RHWA"
echo "== preflight passed"
