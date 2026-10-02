#!/usr/bin/env bash
# test/olmv1/02-nudge.sh KEY — re-apply the (edited) installer ClusterRole and annotate the
# ClusterExtension so operator-controller reconciles immediately instead of waiting out its backoff.
source "$(dirname "$0")/lib.sh"
key="${1:?operator key}"; pkg=$(op_package "$key")
record "02-$key-reapply-clusterrole" apply -f "$(dirname "$0")/rbac/$key/10-clusterrole.yaml" >/dev/null
record "02-$key-nudge" annotate clusterextension "$pkg" "exp0001/retry=$(date -u +%s)" --overwrite >/dev/null
echo "nudged $pkg; now re-run 02-install.sh $key"
