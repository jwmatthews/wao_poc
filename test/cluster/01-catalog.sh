#!/usr/bin/env bash
# test/cluster/01-catalog.sh — WAO-INST-01: the WAO ClusterCatalog serves the package.
# Applies the ClusterCatalog rendered by `make clustercatalog` (full-run.sh build) and waits for Serving=True.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-01 catalog"
[ -f "$CLUSTERCATALOG_FILE" ] || { echo "FAIL: $CLUSTERCATALOG_FILE missing; run \`bash test/cluster/full-run.sh build\`" >&2; exit 1; }
record 01-apply-clustercatalog apply -f "$CLUSTERCATALOG_FILE" >/dev/null
wait_for 300 "ClusterCatalog $CLUSTERCATALOG Serving" catalog_serving "$CLUSTERCATALOG"
record 01-clustercatalog get clustercatalog "$CLUSTERCATALOG" -o json >/dev/null
expect "ClusterCatalog $CLUSTERCATALOG is Serving" catalog_serving "$CLUSTERCATALOG"
expect "ClusterCatalog $CLUSTERCATALOG resolved its image to a digest" \
  jcheck '"@sha256:" in o["status"]["resolvedSource"]["image"]["ref"]' get clustercatalog "$CLUSTERCATALOG"
expect "ClusterCatalog $CLUSTERCATALOG carries the name label the ClusterExtension selector uses" \
  jcheck 'o["metadata"]["labels"].get("olm.operatorframework.io/metadata.name") == os.environ["CLUSTERCATALOG"]' \
  get clustercatalog "$CLUSTERCATALOG"
