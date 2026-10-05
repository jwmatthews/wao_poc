#!/usr/bin/env bash
# test/olmv1/02-install.sh KEY — experiment 0001 step 2/3 for one operator:
# apply its installer ServiceAccount/ClusterRole/ClusterRoleBinding and ClusterExtension, wait for
# Installed=True, then record what OLM v1 rendered (CRDs, Deployment, Services, webhook configs,
# cert Secrets by name, volume mounts). Records a FAIL outcome with the full status on failure.
# Usage: bash test/olmv1/02-install.sh nhc
source "$(dirname "$0")/lib.sh"
key="${1:?operator key (nhc|snr|far|mdr|nmo|sbr)}"
pkg=$(op_package "$key"); ver=$(op_version "$key"); dep=$(op_deployment "$key")
rbac_dir="$(dirname "$0")/rbac/$key"
[ -d "$rbac_dir" ] || { echo "missing $rbac_dir; run gen-installer-rbac.py" >&2; exit 2; }
echo "== 0001-02 install $pkg $ver via ClusterExtension"

# Installer RBAC first, then the extension. Keep the exact manifests applied in the run dir.
cp "$rbac_dir"/*.yaml "${RUN_DIR}/raw/" 2>/dev/null || true
if [ "${SKIP_INSTALLER_RBAC:-0}" = 1 ]; then
  echo "SKIP_INSTALLER_RBAC=1: no installer SA/ClusterRole applied; spec.serviceAccount stripped from the ClusterExtension"
else
  for f in 00-serviceaccount 10-clusterrole 20-clusterrolebinding; do
    record "02-$key-apply-$f" apply -f "$rbac_dir/$f.yaml" >/dev/null
  done
  rules=$(python3 -c 'import yaml,sys; print(len(yaml.safe_load(open(sys.argv[1]))["rules"]))' "$rbac_dir/10-clusterrole.yaml" 2>/dev/null || echo "?")
  echo "installer ClusterRole rules: $rules"
fi
apply_ce "02-$key-apply-ce" "$rbac_dir/30-clusterextension.yaml" >/dev/null

# Wait for Installed=True/Succeeded. Fail fast if operator-controller reports an installer-RBAC
# "forbidden" (the retry backoff grows long; after fixing the ClusterRole, annotate the extension to
# trigger an immediate reconcile, see 02-nudge.sh). Otherwise wait up to 600s.
rbac_forbidden() {
  k get clusterextension "$pkg" -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.message}{end}' 2>/dev/null \
    | grep -q 'attempting to grant RBAC permissions not currently held\|is forbidden'
}
start=$(date +%s)
while ! ce_installed "$pkg"; do
  if rbac_forbidden; then
    echo "INSTALLER RBAC INSUFFICIENT for $pkg:" >&2
    k get clusterextension "$pkg" -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.message}{end}' | sed 's/^/    /' >&2
    record "02-$key-ce-status-rbac" get clusterextension "$pkg" -o json >/dev/null || true
    outcome "0001-02-$key" FAIL "installer RBAC insufficient; see rbac-iterations.md"
    exit 3
  fi
  if (( $(date +%s) - start > 600 )); then break; fi
  sleep 10
done
if ! wait_for 30 "ClusterExtension $pkg Installed=True" ce_installed "$pkg"; then
  record "02-$key-ce-status-failed" get clusterextension "$pkg" -o json >/dev/null || true
  k get clusterextension "$pkg" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' || true
  outcome "0001-02-$key" FAIL "ClusterExtension did not reach Installed=True in 600s"
  exit 1
fi
wait_for 120 "ClusterExtension $pkg not Progressing" ce_not_progressing "$pkg" || true
record "02-$key-ce" get clusterextension "$pkg" -o json >/dev/null
k get clusterextension "$pkg" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
echo "installed bundle: $(k get clusterextension "$pkg" -o jsonpath='{.status.install.bundle.name}') version $(k get clusterextension "$pkg" -o jsonpath='{.status.install.bundle.version}')"

for crd in $(op_crds "$key"); do
  expect "CRD $crd established" crd_established "$crd"
done
expect "manager Deployment $dep available" bash -c "$(declare -f k deployment_available); export NS='$NS'; timeout_s=300; start=\$(date +%s); until deployment_available '$dep'; do [ \$(( \$(date +%s) - start )) -gt \$timeout_s ] && exit 1; sleep 5; done"

# What v1 rendered for admission. Secrets: names and data key names only, never values.
record "02-$key-webhooks" get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json >/dev/null
record "02-$key-deploy" get deployment "$dep" -n "$NS" -o json >/dev/null
record "02-$key-svc" get service -n "$NS" -o json >/dev/null
record "02-$key-secret-names" get secret -n "$NS" -o custom-columns='NAME:.metadata.name,TYPE:.type' >/dev/null
echo "--- cert volumes and mounts on $dep:"
k get deployment "$dep" -n "$NS" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)["spec"]["template"]["spec"]
for v in d.get("volumes", []):
    s = v.get("secret", {})
    if s: print("  volume", v["name"], "secret", s.get("secretName"), "items", [i.get("path") for i in s.get("items", [])])
for c in d.get("containers", []):
    for m in c.get("volumeMounts", []):
        print("  mount", c["name"], m["name"], "->", m["mountPath"])'
echo "--- service annotations (serving-cert-secret-name) in $NS:"
k get service -n "$NS" -o json | python3 -c '
import json, sys
for s in json.load(sys.stdin)["items"]:
    a = s["metadata"].get("annotations", {})
    print("  ", s["metadata"]["name"], a.get("service.beta.openshift.io/serving-cert-secret-name", "-"))'
echo "--- webhook configurations for $pkg (name, failurePolicy, caBundle present, inject-cabundle annotation):"
k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json | python3 -c '
import json, sys
key = sys.argv[1]
for w in json.load(sys.stdin)["items"]:
    if key not in w["metadata"]["name"]: continue
    ann = w["metadata"].get("annotations", {}).get("service.beta.openshift.io/inject-cabundle", "-")
    for h in w.get("webhooks", []):
        print("  ", w["kind"], w["metadata"]["name"], h["name"], h.get("failurePolicy"), "caBundle" if h.get("clientConfig", {}).get("caBundle") else "NO-CABUNDLE", "inject-cabundle=" + ann)' "$pkg"
snapshot "02-$key"
outcome "0001-02-$key" PASS "Installed=True, CRDs established, manager available"
