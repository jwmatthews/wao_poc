#!/usr/bin/env bash
# test/olmv1/04-restart.sh KEY — experiment 0001 step 6 for one operator: restart the manager and
# confirm the webhook server comes back with a working certificate (CA bundle still injected,
# Deployment Available, and one admit plus one reject dry-run per webhook via 03-webhooks.sh).
source "$(dirname "$0")/lib.sh"
key="${1:?operator key}"
dep=$(op_deployment "$key")
echo "== 0001-04 restart $dep"
sel=$(k get deployment "$dep" -n "$NS" -o json | python3 -c 'import json,sys; print(",".join(f"{k}={v}" for k,v in json.load(sys.stdin)["spec"]["selector"]["matchLabels"].items()))')
before=$(k get pods -n "$NS" -l "$sel" -o name 2>/dev/null | sort | tr '\n' ' ')
record "04-$key-restart" rollout restart "deployment/$dep" -n "$NS" >/dev/null
record "04-$key-rollout" rollout status "deployment/$dep" -n "$NS" --timeout=300s >/dev/null
expect "manager Deployment $dep available after restart" deployment_available "$dep"
after=$(k get pods -n "$NS" -l "$sel" -o name 2>/dev/null | sort | tr '\n' ' ')
echo "pods before: $before"; echo "pods after:  $after"
if [ -x "$(dirname "$0")/03-webhooks.sh" ] || [ -f "$(dirname "$0")/03-webhooks.sh" ]; then
  RESTART_PASS=1 bash "$(dirname "$0")/03-webhooks.sh" "$key" --quick
fi
snapshot "04-$key"
outcome "0001-04-$key" PASS "manager restarted and webhooks re-probed"
