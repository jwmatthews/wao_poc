#!/usr/bin/env bash
# test/olmv1/03-webhooks.sh KEY [--quick] — experiment 0001 step 5: run the admission matrix for one
# operator with server-side dry-run only. See webhooks.py and samples/README.md.
source "$(dirname "$0")/lib.sh"
key="${1:?operator key}"; shift || true
echo "== 0001-03 webhook matrix for $key $*"
record "03-$key-webhooks-before" get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >/dev/null
RUN_DIR="$RUN_DIR" "$PYTHON" "$(dirname "$0")/webhooks.py" "$key" "$@"
