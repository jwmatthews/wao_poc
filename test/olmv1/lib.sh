# test/olmv1/lib.sh — helpers for the OLM v1 experiments. Bash 3.2 compatible.
# shellcheck shell=bash
# Same conventions as test/cluster/lib.sh: every predicate checks each step; an API error is a
# failure, never "absent". Raw output goes to $RUN_DIR/raw (git-ignored) and may contain cluster
# identifiers; only sanitized summaries are ever committed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

k() { "${OC}" --kubeconfig "${KUBECONFIG}" --request-timeout=30s "$@"; }
export -f k

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

# outcome CASE RESULT [NOTE] : append one line to $RUN_DIR/outcomes.tsv.
outcome() { printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$1" "$2" "${3:-}" >> "${RUN_DIR}/outcomes.tsv"; }

wait_for() {
  local limit="$1" desc="$2"; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > limit )); then echo "TIMEOUT: $desc" >&2; return 1; fi
    sleep 5
  done
  echo "ok: $desc"
}
expect() {
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc" >&2; return 1; fi
}

# jcheck PYEXPR ARGS... : `k ARGS -o json` succeeds and PYEXPR (o = parsed JSON) is truthy.
jcheck() {
  local expr="$1"; shift
  local out
  out=$(k "$@" -o json) || return 1
  printf '%s' "$out" | python3 -c '
import json, os, sys
o = json.load(sys.stdin)
sys.exit(0 if eval("(" + sys.argv[1] + "\n)") else 1)' "$expr"
}
absent() { local out; out=$(k get "$@" --ignore-not-found -o name) || return 1; [ -z "$out" ]; }
found() { local out; out=$(k get "$@" -o name) || return 1; [ -n "$out" ]; }

# apply_ce LABEL FILE : apply a ClusterExtension manifest. With SKIP_INSTALLER_RBAC=1 (OCP 5.0+, where
# spec.serviceAccount is deprecated and ignored and operator-controller runs as cluster-admin), strip
# spec.serviceAccount first and keep the stripped manifest in the run dir. `record` keeps the apply's
# stderr, so any deprecation warning the API server emits is in the raw evidence.
apply_ce() {
  local label="$1" file="$2"
  if [ "${SKIP_INSTALLER_RBAC:-0}" = 1 ]; then
    local stripped="${RUN_DIR}/raw/$(basename "$file" .yaml)-nosa.yaml"
    "$PYTHON" - "$file" "$stripped" <<'PY'
import sys, yaml
o = yaml.safe_load(open(sys.argv[1])); o["spec"].pop("serviceAccount", None)
yaml.safe_dump(o, open(sys.argv[2], "w"), sort_keys=False)
PY
    file="$stripped"
  fi
  record "$label" apply -f "$file"
}

# ce_condition NAME TYPE : print "status/reason" of a ClusterExtension condition.
ce_condition() {
  k get clusterextension "$1" -o json | python3 -c '
import json, sys
o = json.load(sys.stdin)
c = [x for x in o.get("status", {}).get("conditions", []) if x["type"] == sys.argv[1]]
print((c[0]["status"] + "/" + c[0].get("reason", "")) if c else "absent")' "$2"
}
ce_installed() { [ "$(ce_condition "$1" Installed)" = "True/Succeeded" ]; }
ce_not_progressing() { case "$(ce_condition "$1" Progressing)" in False/*|True/Succeeded) return 0 ;; *) return 1 ;; esac; }
deployment_available() { k wait "deployment/$1" -n "$NS" --for=condition=Available --timeout=10s >/dev/null; }
crd_established() { k wait "crd/$1" --for=condition=Established --timeout=10s >/dev/null; }

# ca_injected OBJ : every webhook in OBJ has a non-empty caBundle.
ca_injected() {
  jcheck 'o.get("webhooks") and all(w.get("clientConfig", {}).get("caBundle") for w in o["webhooks"])' get "$1"
}

# snapshot LABEL : persist the objects every case compares. Never captures Secret values.
snapshot() {
  local l="$1"
  record "${l}-ce" get clusterextension -o json >/dev/null || true
  record "${l}-deploy" get deployment -n "$NS" -o json >/dev/null || true
  record "${l}-ds" get daemonset -n "$NS" -o json >/dev/null || true
  record "${l}-pods" get pods -n "$NS" -o wide >/dev/null || true
  record "${l}-svc" get service -n "$NS" -o json >/dev/null || true
  record "${l}-webhooks" get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >/dev/null || true
  record "${l}-crds" get crd -o json >/dev/null || true
  record "${l}-secrets-names" get secret -n "$NS" -o custom-columns='NAME:.metadata.name,TYPE:.type,KEYS:.data' >/dev/null || true
}
