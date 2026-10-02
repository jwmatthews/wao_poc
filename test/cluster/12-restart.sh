#!/usr/bin/env bash
# test/cluster/12-restart.sh — WAO-INST-12: restarting WAO changes nothing it manages.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-12 WAO restart idempotence"

# state FILE : write the comparable state (generations, pods, config resourceVersion, conditions) as JSON.
state() {
  local d; d=$(mktemp -d)
  k get deployment -n "$NS" -l workloadavailability.medik8s.io/component -o json >"$d/deploy" &&
    k get validatingwebhookconfigurations,mutatingwebhookconfigurations -l workloadavailability.medik8s.io/component -o json >"$d/webhooks" &&
    k get pods -n "$NS" -l "app.kubernetes.io/name!=workload-availability-operator" -o json >"$d/pods" &&
    k get wac cluster -o json >"$d/wac" || { rm -rf "$d"; return 1; }
  python3 - "$1" "$d" <<'PY'
import json, sys
path, d = sys.argv[1], sys.argv[2]
load = lambda n: json.load(open(f"{d}/{n}"))
gen = lambda l: {i["kind"] + "/" + i["metadata"]["name"]: i["metadata"].get("generation") for i in l["items"]}
wac = load("wac")
json.dump({
    "deployments": gen(load("deploy")),
    "webhooks": gen(load("webhooks")),
    "pods": {p["metadata"]["name"]: [p["metadata"]["uid"], sum(c.get("restartCount", 0) for c in p["status"].get("containerStatuses") or [])]
             for p in load("pods")["items"]},
    "wac_resourceVersion": wac["metadata"]["resourceVersion"],
    "conditions": {c["type"]: [c["status"], c["lastTransitionTime"]] for c in wac["status"].get("conditions") or []},
}, open(path, "w"), indent=1, sort_keys=True)
PY
  local rc=$?; rm -rf "$d"; return $rc
}
before="${RUN_DIR}/raw/12-state-before.json"; after="${RUN_DIR}/raw/12-state-after.json"
state "$before"
expect "operand Deployments recorded (all six components enabled)" \
  python3 -c 'import json,sys; sys.exit(0 if len(json.load(open(sys.argv[1]))["deployments"]) == 6 else 1)' "$before"

# Watch the config for resourceVersion changes while WAO restarts. No --request-timeout: it is a watch.
watch_file="${RUN_DIR}/raw/12-wac-watch.txt"
"${OC}" --kubeconfig "${KUBECONFIG}" get workloadavailabilityconfig cluster --watch-only \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}' >"$watch_file" 2>&1 &
watch_pid=$!
trap 'kill $watch_pid 2>/dev/null || true' EXIT
sleep 2
start=$(date +%s)
restart_wao 12
remaining=$(( 120 - ($(date +%s) - start) ))
if [ "$remaining" -gt 0 ]; then echo "waiting ${remaining}s to complete the 2-minute window"; sleep "$remaining"; fi
watch_alive=yes; kill -0 "$watch_pid" 2>/dev/null || watch_alive=no
kill "$watch_pid" 2>/dev/null || true
state "$after"

cmp_key() { python3 -c 'import json,sys; a,b=(json.load(open(f)) for f in sys.argv[1:3]); sys.exit(0 if a[sys.argv[3]] == b[sys.argv[3]] else 1)' "$before" "$after" "$1"; }
expect "operand Deployment generations unchanged" cmp_key deployments
expect "webhook configuration generations unchanged" cmp_key webhooks
expect "no operand or agent pod replaced or restarted" cmp_key pods
expect "all conditions keep status and lastTransitionTime" cmp_key conditions
changes=$(grep -Ec '^[0-9]+$' "$watch_file" || true)
[ "$watch_alive" = yes ] || echo "note: config watch ended early; change count relies on before/after resourceVersion"
rv_changes() {
  local differs=0
  cmp_key wac_resourceVersion || differs=1
  [ "$changes" -le 1 ] && { [ "$watch_alive" = yes ] || [ "$differs" -eq 0 ] || [ "$changes" -eq 1 ]; }
}
echo "note: config resourceVersion changed ${changes} time(s) during the restart window"
expect "config resourceVersion changed at most once" rv_changes
snapshot 12
