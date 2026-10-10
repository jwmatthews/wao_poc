# test/cluster/lib.sh — shared helpers for the live-cluster case scripts. Bash 3.2 compatible.
# shellcheck shell=bash
#
# Helpers used as `expect`/`wait_for` predicates run with errexit suspended (bash rule for
# commands in `if`/`until`), so every predicate below checks each step explicitly and never
# relies on `set -e`. An API error is always a failure, never "absent" or "empty".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# The twelve component CRDs plus the WA config CRD (design brief D8).
COMPONENT_CRDS="nodehealthchecks.remediation.medik8s.io
selfnoderemediationconfigs.self-node-remediation.medik8s.io
selfnoderemediations.self-node-remediation.medik8s.io
selfnoderemediationtemplates.self-node-remediation.medik8s.io
storagebasedremediationconfigs.storage-based-remediation.medik8s.io
storagebasedremediations.storage-based-remediation.medik8s.io
storagebasedremediationtemplates.storage-based-remediation.medik8s.io
fenceagentsremediations.fence-agents-remediation.medik8s.io
fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io
machinedeletionremediations.machine-deletion-remediation.medik8s.io
machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io
nodemaintenances.nodemaintenance.medik8s.io"
WAC_CRD="workloadavailabilityconfigs.workloadavailability.medik8s.io"
ALL_CRDS="${WAC_CRD}
${COMPONENT_CRDS}"
COMPONENT_KEYS="nodeHealthCheck selfNodeRemediation storageBasedRemediation fenceAgentsRemediation machineDeletionRemediation nodeMaintenance"
# Every admission webhook name the four webhook-serving components register.
MEDIK8S_WEBHOOKS="vnodehealthcheck.kb.io mselfnoderemediationtemplate.kb.io vselfnoderemediation.kb.io vselfnoderemediationconfig.kb.io vselfnoderemediationtemplate.kb.io mfenceagentsremediation.kb.io mfenceagentsremediationtemplate.kb.io vfenceagentsremediation.kb.io vfenceagentsremediationtemplate.kb.io vnodemaintenance.kb.io"
export COMPONENT_CRDS WAC_CRD ALL_CRDS COMPONENT_KEYS MEDIK8S_WEBHOOKS

k() { "${OC}" --kubeconfig "${KUBECONFIG}" --request-timeout=30s "$@"; }
export -f k   # usable inside `bash -c` subshells

# record NAME ARGS... : run k ARGS, save {command, exit_code, stdout, stderr} as JSON, echo stdout.
record() {
  local name="$1"; shift
  local ts tmpo tmpe code=0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; tmpo="$(mktemp)"; tmpe="$(mktemp)"
  k "$@" >"$tmpo" 2>"$tmpe" || code=$?
  python3 - "${RUN_DIR}/raw/${ts}-${name}.json" "$code" "$tmpo" "$tmpe" "$*" <<'PY'
import json, sys
path, code, outf, errf, cmd = sys.argv[1:6]
json.dump({"command": cmd.split(), "exit_code": int(code), "stdout": open(outf).read(), "stderr": open(errf).read()}, open(path, "w"), indent=1)
PY
  cat "$tmpo"; cat "$tmpe" >&2
  rm -f "$tmpo" "$tmpe"
  return $code
}

# wait_for SECONDS DESCRIPTION COMMAND... : poll every 5s until COMMAND succeeds.
wait_for() {
  local limit="$1" desc="$2"; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > limit )); then echo "TIMEOUT: $desc" >&2; return 1; fi
    sleep 5
  done
  echo "ok: $desc"
}

# expect DESCRIPTION COMMAND... : fail the case when COMMAND fails.
expect() {
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc" >&2; return 1; fi
}

# component_field KEY FIELD : print one field of a component status entry ("null" when unset).
component_field() {
  k get workloadavailabilityconfig cluster -o json | python3 -c '
import json, sys
s = json.load(sys.stdin).get("status", {})
c = [x for x in s.get("components", []) if x["name"] == sys.argv[1]]
v = c[0].get(sys.argv[2]) if c else None
print(json.dumps(v) if not isinstance(v, str) else v)' "$1" "$2"
}
export -f component_field

# snapshot LABEL : persist the objects every case compares. Never captures Secrets.
snapshot() {
  local l="$1"
  record "${l}-csv" get csv -n "$NS" -o json >/dev/null || true
  record "${l}-deploy" get deployment -n "$NS" -o json >/dev/null || true
  record "${l}-ds" get daemonset -n "$NS" -o json >/dev/null || true
  record "${l}-pods" get pods -n "$NS" -o wide >/dev/null || true
  record "${l}-webhooks" get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >/dev/null || true
  record "${l}-wac" get workloadavailabilityconfig cluster -o json >/dev/null || true
}

# ---- predicates -------------------------------------------------------------------------------

# jcheck PYEXPR ARGS... : `k ARGS -o json` succeeds and PYEXPR (with `o` = parsed JSON, `os` imported,
# so os.environ gives exported settings) is truthy.
jcheck() {
  local expr="$1"; shift
  local out
  out=$(k "$@" -o json) || return 1
  printf '%s' "$out" | python3 -c '
import json, os, sys
o = json.load(sys.stdin)
sys.exit(0 if eval("(" + sys.argv[1] + "\n)") else 1)' "$expr"
}

# none_found ARGS... : `k get ARGS -o name` succeeds and lists nothing.
none_found() { local out; out=$(k get "$@" -o name) || return 1; [ -z "$out" ]; }

# found ARGS... : `k get ARGS -o name` succeeds and lists something.
found() { local out; out=$(k get "$@" -o name) || return 1; [ -n "$out" ]; }

# absent ARGS... : the named object does not exist. Any other API error fails.
# An API error (for example a TLS handshake timeout on a busy control plane) is retried up to three times; a
# successful read that finds the object still fails the check.
absent() {
  local out try
  for try in 1 2 3; do
    if out=$(k get "$@" --ignore-not-found -o name); then [ -z "$out" ]; return; fi
    sleep 5
  done
  return 1
}

# deployment_available NAME : Deployment NAME in $NS has condition Available=True.
deployment_available() { k wait "deployment/$1" -n "$NS" --for=condition=Available --timeout=10s >/dev/null; }

# phase_is KEY PHASE : component KEY reports PHASE.
phase_is() { local p; p=$(component_field "$1" phase) || return 1; [ "$p" = "$2" ]; }

# field_is KEY FIELD VALUE : component KEY field FIELD prints VALUE (true, false, null, ...).
field_is() { local v; v=$(component_field "$1" "$2") || return 1; [ "$v" = "$3" ]; }

# ca_injected KIND/NAME : the webhook configuration exists, has webhooks, and every one carries a caBundle.
ca_injected() {
  jcheck 'len(o.get("webhooks") or []) > 0 and all((w.get("clientConfig") or {}).get("caBundle") for w in o["webhooks"])' get "$1"
}

# secret_key_names NAMESPACE NAME : print the data key NAMES of a Secret. Never prints values.
secret_key_names() {
  k get secret "$2" -n "$1" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
}

# secret_has_keys NAMESPACE NAME KEY... : the Secret exists and has every KEY (names only).
secret_has_keys() {
  local ns="$1" name="$2" keys; shift 2
  keys=$(secret_key_names "$ns" "$name") || return 1
  local want
  for want in "$@"; do
    printf '%s\n' "$keys" | grep -qx "$want" || return 1
  done
}

# webhook_names : every validating and mutating webhook name in the cluster, one per line.
webhook_names() {
  k get validatingwebhookconfigurations,mutatingwebhookconfigurations \
    -o jsonpath='{range .items[*]}{range .webhooks[*]}{.name}{"\n"}{end}{end}'
}

# no_webhook_matching PATTERN : no registered webhook name matches the grep PATTERN.
no_webhook_matching() { local n; n=$(webhook_names) || return 1; ! printf '%s\n' "$n" | grep -q "$1"; }

# no_medik8s_webhooks : no webhook configuration registers a medik8s component webhook name
# or points at a Service in $NS.
no_medik8s_webhooks() {
  local names svcns w
  names=$(webhook_names) || return 1
  for w in $MEDIK8S_WEBHOOKS; do
    if printf '%s\n' "$names" | grep -qx "$w"; then echo "found webhook $w" >&2; return 1; fi
  done
  svcns=$(k get validatingwebhookconfigurations,mutatingwebhookconfigurations \
    -o jsonpath='{range .items[*]}{range .webhooks[*]}{.clientConfig.service.namespace}{"\n"}{end}{end}') || return 1
  ! printf '%s\n' "$svcns" | grep -qx "$NS"
}

# operand_objects DIR : print "Kind name" for every manifest WAO renders for component DIR
# (nhc, snr, sbr, far, mdr, nmo), from the committed file names NN-Kind-name.yaml.
operand_objects() {
  local f base rest
  for f in "${MANIFESTS}/$1"/*.yaml; do
    base="${f##*/}"; base="${base%.yaml}"; rest="${base#*-}"
    echo "${rest%%-*} ${rest#*-}"
  done
}

# operands_present DIR : every rendered object of component DIR exists.
operands_present() {
  local kind name rc=0
  while read -r kind name; do
    found "$kind" "$name" -n "$NS" >/dev/null 2>&1 || { echo "missing $kind $name" >&2; rc=1; }
  done < <(operand_objects "$1")
  return $rc
}

# operands_absent DIR : no rendered object of component DIR exists.
operands_absent() {
  local kind name rc=0
  while read -r kind name; do
    absent "$kind" "$name" -n "$NS" >/dev/null || { echo "still present (or API error): $kind $name" >&2; rc=1; }
  done < <(operand_objects "$1")
  return $rc
}

# labelled_absent KEY : nothing carrying the WAO component label KEY remains (namespace and cluster scope).
labelled_absent() {
  none_found deployment,service,serviceaccount,role,rolebinding,configmap -n "$NS" -l "workloadavailability.medik8s.io/component=$1" &&
    none_found clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration -l "workloadavailability.medik8s.io/component=$1"
}

# crds_present LIST : every CRD in the newline-separated LIST exists.
crds_present() {
  local c rc=0
  for c in $1; do found crd "$c" >/dev/null 2>&1 || { echo "missing CRD $c" >&2; rc=1; }; done
  return $rc
}

# no_component_objects : no object of any of the twelve component kinds exists anywhere.
no_component_objects() {
  local c rc=0
  for c in $COMPONENT_CRDS; do
    none_found "$c" -A >/dev/null 2>&1 || { echo "objects (or API error) for $c" >&2; rc=1; }
  done
  return $rc
}

# only_wao_deployment : the WAO controller is the only Deployment in $NS.
only_wao_deployment() {
  local out; out=$(k get deployment -n "$NS" -o name) || return 1
  [ "$out" = "deployment.apps/${WAO_DEPLOYMENT}" ]
}

# set_state CASE KEY STATE : patch one component state on the singleton config (merge patch).
set_state() { record "$1-$2-$3" patch workloadavailabilityconfig cluster --type merge -p "{\"spec\":{\"components\":{\"$2\":{\"state\":\"$3\"}}}}" >/dev/null; }

# dry_run_rejected LABEL VERB : run `k VERB --dry-run=server -f -` on stdin; succeed when the server
# rejects it. The output is saved to raw/LABEL.txt and kept in DRY_RUN_OUT for message checks.
DRY_RUN_OUT=""
dry_run_rejected() {
  local label="$1" verb="$2" code=0
  DRY_RUN_OUT=$(k "$verb" --dry-run=server -f - 2>&1) || code=$?
  printf '%s\n' "$DRY_RUN_OUT" > "${RUN_DIR}/raw/${label}.txt"
  [ "$code" -ne 0 ]
}

# wao_pods : names of the WAO controller pods.
wao_pods() { k get pods -n "$NS" -l "$WAO_POD_SELECTOR" -o jsonpath='{.items[*].metadata.name}'; }

# wao_pod_replaced OLD_NAMES : none of OLD_NAMES exists and a WAO pod is Ready.
wao_pod_replaced() {
  local cur p
  cur=$(wao_pods) || return 1
  [ -n "$cur" ] || return 1
  for p in $1; do case " $cur " in *" $p "*) return 1 ;; esac; done
  k wait pod -n "$NS" -l "$WAO_POD_SELECTOR" --for=condition=Ready --timeout=10s >/dev/null
}

# restart_wao LABEL : delete the WAO controller pod and wait for its replacement to be Ready.
restart_wao() {
  local old; old=$(wao_pods)
  [ -n "$old" ] || { echo "FAIL: no WAO pod found" >&2; return 1; }
  record "$1-delete-wao-pod" delete pod $old -n "$NS" --wait=false >/dev/null
  wait_for 300 "WAO pod replaced and Ready" wao_pod_replaced "$old"
}

# ---- OpenShift platform helpers (design brief D11) -------------------------------------------

# prom_query EXPR : instant query against the platform Prometheus from inside its pod (read-only; the
# upstream NHC readme documents the same path). Prints the JSON result array.
prom_query() {
  k -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
    curl -sG --data-urlencode "query=$1" http://localhost:9090/api/v1/query |
    python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit("prometheus query failed: " + str(d.get("error", d.get("status")))) if d.get("status") != "success" else print(json.dumps(d["data"]["result"]))'
}
export -f prom_query   # usable inside `bash -c` subshells

# prom_all_values EXPR VALUE : every series of EXPR has VALUE, and there is at least one series.
prom_all_values() {
  local out; out=$(prom_query "$1") || return 1
  python3 -c 'import json, sys; r = json.loads(sys.argv[1]); sys.exit(0 if r and all(x["value"][1] == sys.argv[2] for x in r) else 1)' "$out" "$2"
}

# sm_selects_service : the NHC ServiceMonitor's matchLabels are all present on the metrics Service.
sm_selects_service() {
  local sel labels
  sel=$(k get servicemonitor node-healthcheck-controller-manager-metrics-monitor -n "$NS" -o jsonpath='{.spec.selector.matchLabels}') || return 1
  labels=$(k get service node-healthcheck-controller-manager-metrics-service -n "$NS" -o jsonpath='{.metadata.labels}') || return 1
  python3 -c 'import json, sys; s, l = json.loads(sys.argv[1]), json.loads(sys.argv[2]); sys.exit(0 if s and all(l.get(k) == v for k, v in s.items()) else 1)' "$sel" "$labels"
}

# console_plugins : the console's enabled plugin list as a JSON array ("[]" when unset). Never modified by WAO.
console_plugins() {
  local p; p=$(k get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}') || return 1
  printf '%s' "${p:-[]}"
}

# console_plugin_enabled NAME
console_plugin_enabled() {
  local p; p=$(console_plugins) || return 1
  python3 -c 'import json, sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1]) else 1)' "$p" "$1"
}

# enable_console_plugin LABEL NAME : the administrator step. Appends NAME, preserving existing entries.
enable_console_plugin() {
  local p; p=$(console_plugins) || return 1
  python3 -c 'import json, sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1]) else 1)' "$p" "$2" && return 0
  if [ "$p" = "[]" ]; then
    record "$1" patch consoles.operator.openshift.io cluster --type json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/plugins\",\"value\":[\"$2\"]}]" >/dev/null
  else
    record "$1" patch consoles.operator.openshift.io cluster --type json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"$2\"}]" >/dev/null
  fi
}

# disable_console_plugin LABEL NAME : remove NAME from spec.plugins, preserving the other entries.
disable_console_plugin() {
  local p idx
  p=$(console_plugins) || return 1
  idx=$(python3 -c 'import json, sys; l = json.loads(sys.argv[1]); print(l.index(sys.argv[2]) if sys.argv[2] in l else -1)' "$p" "$2")
  [ "$idx" -ge 0 ] || return 0
  record "$1" patch consoles.operator.openshift.io cluster --type json -p "[{\"op\":\"test\",\"path\":\"/spec/plugins/$idx\",\"value\":\"$2\"},{\"op\":\"remove\",\"path\":\"/spec/plugins/$idx\"}]" >/dev/null
}

# trusted_fetch LABEL URL : fetch URL from a short-lived pod in $NS, verifying TLS against the service CA that
# OpenShift publishes in every namespace (ConfigMap openshift-service-ca.crt). Prints the body. No -k anywhere.
trusted_fetch() {
  local pod="wao-fetch-$1" rc=0
  k delete pod "$pod" -n "$NS" --ignore-not-found >/dev/null
  k apply -n "$NS" -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels: {wao-test: fetch}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: curl
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["curl", "-sS", "--fail", "--cacert", "/service-ca/service-ca.crt", "$2"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: service-ca, mountPath: /service-ca, readOnly: true}]
  volumes:
  - name: service-ca
    configMap: {name: openshift-service-ca.crt}
YAML
  if ! k wait pod "$pod" -n "$NS" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1; then
    k logs "$pod" -n "$NS" >&2 || true
    k get pod "$pod" -n "$NS" -o jsonpath='{.status.phase} {.status.containerStatuses[*].state}' >&2 || true
    rc=1
  else
    k logs "$pod" -n "$NS"
  fi
  k delete pod "$pod" -n "$NS" --ignore-not-found >/dev/null
  return $rc
}
