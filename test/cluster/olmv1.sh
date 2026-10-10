# test/cluster/olmv1.sh — OLM v1 (ClusterExtension / ClusterCatalog) predicates for the install cases.
# shellcheck shell=bash
# Sourced by lib.sh after k, jcheck, found and absent are defined. Bash 3.2 compatible.
# Every predicate fails on an API error; "absent" is never inferred from an error.

# ce_condition NAME TYPE : print "status/reason" of a ClusterExtension condition, or "absent".
ce_condition() {
  k get clusterextension "$1" -o json | python3 -c '
import json, sys
o = json.load(sys.stdin)
c = [x for x in o.get("status", {}).get("conditions", []) if x["type"] == sys.argv[1]]
print((c[0]["status"] + "/" + c[0].get("reason", "")) if c else "absent")' "$2"
}
ce_installed() { [ "$(ce_condition "$1" Installed)" = "True/Succeeded" ]; }
ce_progressing_succeeded() { [ "$(ce_condition "$1" Progressing)" = "True/Succeeded" ]; }
# ce_installed_bundle NAME : print status.install.bundle.name (empty until installed).
ce_installed_bundle() { k get clusterextension "$1" -o jsonpath='{.status.install.bundle.name}'; }
# catalog_serving NAME : the ClusterCatalog reports Serving=True.
catalog_serving() {
  jcheck 'any(c["type"] == "Serving" and c["status"] == "True" for c in o.get("status", {}).get("conditions", []))' \
    get clustercatalog "$1"
}
olmv1_present() {
  found crd clusterextensions.olm.operatorframework.io >/dev/null && found crd clustercatalogs.olm.operatorframework.io >/dev/null
}
# ce_sa_required : exit 0 when the ClusterExtension CRD still requires spec.serviceAccount (OpenShift 4.18–4.22);
# exit 1 when the field is optional and ignored (OpenShift 5.0+). Any API error exits 1 as well.
ce_sa_required() {
  jcheck '"serviceAccount" in next(v for v in o["spec"]["versions"] if v.get("storage"))["schema"]["openAPIV3Schema"]["properties"]["spec"].get("required", [])' \
    get crd clusterextensions.olm.operatorframework.io
}
