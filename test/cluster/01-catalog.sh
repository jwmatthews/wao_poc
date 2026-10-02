#!/usr/bin/env bash
# test/cluster/01-catalog.sh — WAO-INST-01: the POC ConfigMap-backed catalog serves the WAO package.
source "$(dirname "$0")/lib.sh"
echo "== WAO-INST-01 catalog"
[ -f "$CATALOG_FILE" ] || { echo "FAIL: $CATALOG_FILE missing; run \`make catalog-configmap\`" >&2; exit 1; }
record 01-apply-catalog apply -f "$CATALOG_FILE" >/dev/null

catalog_ready() {
  local s; s=$(k get catalogsource "$CATALOG" -n "$CAT_NS" -o jsonpath='{.status.connectionState.lastObservedState}') || return 1
  [ "$s" = READY ]
}
wait_for 180 "CatalogSource $CATALOG READY" catalog_ready

package_has_channel() {
  jcheck 'any(i["metadata"]["name"] == os.environ["PACKAGE"] and os.environ["CHANNEL"] in [c["name"] for c in i["status"].get("channels") or []] for i in o["items"])' \
    get packagemanifest -n "$CAT_NS" -l "catalog=${CATALOG}"
}
wait_for 180 "packagemanifest $PACKAGE from $CATALOG lists channel $CHANNEL" package_has_channel
record 01-packagemanifest get packagemanifest -n "$CAT_NS" -l "catalog=${CATALOG}" -o json >/dev/null
expect "packagemanifest $PACKAGE lists channel $CHANNEL" package_has_channel
