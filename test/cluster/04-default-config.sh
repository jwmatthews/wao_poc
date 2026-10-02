#!/usr/bin/env bash
# test/cluster/04-default-config.sh — WAO-INST-04: default config (D4), status, release set and singleton CEL rule.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-04 default config, status and CEL"

status_complete() { jcheck 'len(o.get("status", {}).get("components") or []) == 6 and o["status"].get("conditions")' get wac cluster; }
wait_for 120 "WAO created config 'cluster' with six component statuses" status_complete
record 04-wac get workloadavailabilityconfig cluster -o yaml >/dev/null

all_disabled() {
  jcheck 'all(o.get("spec", {}).get("components", {}).get(k, {}).get("state", "Disabled") == "Disabled" for k in os.environ["COMPONENT_KEYS"].split())
and sorted(c["name"] for c in o["status"]["components"]) == sorted(os.environ["COMPONENT_KEYS"].split())
and all(c["phase"] == "Disabled" and c["desiredState"] == "Disabled" for c in o["status"]["components"])' get wac cluster
}
expect "six component entries, all Disabled (spec, desiredState and phase)" all_disabled
expect "no retainedResources on any component" jcheck 'not any(c.get("retainedResources") for c in o["status"]["components"])' get wac cluster
expect "finalizer workloadavailability.medik8s.io/finalizer set" \
  jcheck '"workloadavailability.medik8s.io/finalizer" in (o["metadata"].get("finalizers") or [])' get wac cluster

cond() { # cond TYPE STATUS [REASON]
  T="$1" S="$2" R="${3:-}" jcheck '[c for c in o["status"]["conditions"] if c["type"] == os.environ["T"] and c["status"] == os.environ["S"] and (not os.environ["R"] or c["reason"] == os.environ["R"])]' get wac cluster
}
expect "Available=True reason AsExpected" cond Available True AsExpected
expect "Progressing=False" cond Progressing False
expect "Degraded=False" cond Degraded False

expected_release_set=$("$PYTHON" -c '
import json, sys, yaml
rs = yaml.safe_load(open(sys.argv[1]))
print(json.dumps({env: i["pinned"] for c in rs["components"].values() for env, i in c["images"].items()}, sort_keys=True))' \
  "${REPO_ROOT}/release-set.yaml")
export EXPECTED_RELEASE_SET="$expected_release_set"
expect "status.releaseSet equals the seven pinned images in release-set.yaml" \
  jcheck 'len(json.loads(os.environ["EXPECTED_RELEASE_SET"])) == 7 and {r["name"]: r["image"] for r in o["status"].get("releaseSet") or []} == json.loads(os.environ["EXPECTED_RELEASE_SET"])' get wac cluster

expect "a config named 'other' is rejected (server dry-run)" dry_run_rejected 04-cel-other create <<'YAML'
apiVersion: workloadavailability.medik8s.io/v1alpha1
kind: WorkloadAvailabilityConfig
metadata:
  name: other
spec: {}
YAML
expect "rejection carries the singleton message" grep -q "singleton and must be named 'cluster'" <<<"$DRY_RUN_OUT"
expect "no config named 'other' exists" absent wac other
snapshot 04
