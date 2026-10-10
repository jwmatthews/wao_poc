#!/usr/bin/env python3
"""Extract WAO operand manifests from fetched upstream OLM bundles.

Inputs: .cache/bundles/<component>/manifests (from hack/fetch-bundles.py) and release-set.yaml.
Outputs: deterministic YAML for the Go renderer (go:embed), the component CRDs for the WAO
CSV, and the union ClusterRole that lets WAO create component RBAC (RBAC escalation prevention).

All six operands share one namespace, so a cross-component pass (design brief D10) labels every
operand pod with its component, narrows any Service selector that would also match another
component's pods, and rejects duplicate object identities across components.
"""
import argparse
import copy
import hashlib
import json
import pathlib
import sys

import yaml

NAMESPACE_PLACEHOLDER = "__WAO_NAMESPACE__"
# kustomize placeholder namespaces that bundles sometimes leave in RBAC subjects (D9)
PLACEHOLDER_NAMESPACES = {"system", "sbr-operator-system", "node-healthcheck-operator-system", "self-node-remediation-system"}
NAMESPACED_KINDS = {"Deployment", "Service", "ConfigMap", "Role", "RoleBinding", "ServiceAccount", "Secret"}
WEBHOOK_CERT_DIR = "/tmp/k8s-webhook-server/serving-certs"  # controller-runtime default; upstream managers fall back to it
COMPONENT_LABEL = "workloadavailability.medik8s.io/component"
# Name suffix of the cluster-wide copy of a CSV's namespaced permissions (OLM AllNamespaces behaviour).
ALL_NAMESPACES_SUFFIX = "-all-namespaces"
# Rule OLM appends to the cluster-wide copy of a CSV's namespaced permissions for an AllNamespaces OperatorGroup.
OLM_NAMESPACES_RULE = {"apiGroups": [""], "resources": ["namespaces"], "verbs": ["get", "list", "watch"]}
SERVING_CERT_ANNOTATION = "service.beta.openshift.io/serving-cert-secret-name"
INJECT_CABUNDLE_ANNOTATION = "service.beta.openshift.io/inject-cabundle"
OPTIONAL_WEBHOOK_FIELDS = {
    "ValidatingWebhookConfiguration": ("timeoutSeconds", "objectSelector", "matchPolicy"),
    "MutatingWebhookConfiguration": ("timeoutSeconds", "objectSelector", "matchPolicy", "reinvocationPolicy"),
}
ORDER = {"ServiceAccount": "00", "ClusterRole": "10", "ClusterRoleBinding": "11", "Role": "20", "RoleBinding": "21",
         "ConfigMap": "30", "Service": "40", "Deployment": "50",
         "ValidatingWebhookConfiguration": "60", "MutatingWebhookConfiguration": "61"}

# key: the WorkloadAvailabilityConfig API key, also the value of COMPONENT_LABEL on operand pods.
COMPONENTS = {
    "nhc": {"key": "nodeHealthCheck", "prefix": "node-healthcheck", "webhook_service": "node-healthcheck-webhook-service",
            "webhook_deployment": "node-healthcheck-controller-manager",
            # OLM creates ServiceAccounts from CSV permissions, so the bundle cannot carry upstream's
            # config/optional/console-plugin/service_account.yaml setting; WAO restores it (design brief D11).
            "automount_disabled": ["node-healthcheck-console-plugin"]},
    "snr": {"key": "selfNodeRemediation", "prefix": "self-node-remediation", "webhook_service": "self-node-remediation-webhook-service",
            "webhook_deployment": "self-node-remediation-controller-manager"},
    "sbr": {"key": "storageBasedRemediation", "prefix": "sbr-operator", "webhook_service": None, "webhook_deployment": None},
    "far": {"key": "fenceAgentsRemediation", "prefix": "fence-agents-remediation", "webhook_service": "fence-agents-remediation-webhook-service",
            "webhook_deployment": "fence-agents-remediation-controller-manager"},
    "mdr": {"key": "machineDeletionRemediation", "prefix": "machine-deletion-remediation", "webhook_service": None, "webhook_deployment": None},
    "nmo": {"key": "nodeMaintenance", "prefix": "node-maintenance-operator", "webhook_service": "node-maintenance-operator-webhook-service",
            "webhook_deployment": "node-maintenance-operator-controller-manager"},
}

# Permissions WAO itself needs beyond the component union.
WAO_OWN_RULES = [
    {"apiGroups": ["rbac.authorization.k8s.io"], "resources": ["roles", "rolebindings", "clusterroles", "clusterrolebindings"],
     "verbs": ["create", "delete", "get", "list", "patch", "update", "watch", "bind"]},
    {"apiGroups": ["admissionregistration.k8s.io"], "resources": ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"],
     "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]},
    {"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]},
    {"apiGroups": ["apps"], "resources": ["daemonsets"], "verbs": ["get", "list", "watch"]},
    {"apiGroups": [""], "resources": ["services", "serviceaccounts", "configmaps"],
     "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]},
    {"apiGroups": [""], "resources": ["events"], "verbs": ["create", "patch"]},
]


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def dump(obj):
    return yaml.safe_dump(obj, sort_keys=True, default_flow_style=False, width=4096)


def load_bundle(cache, name):
    root = pathlib.Path(cache) / name
    fetch = json.loads((root / "fetch.json").read_text())
    csv, crds, others, inputs = None, [], [], {}
    for f in sorted((root / "manifests").iterdir()):
        inputs[f.name] = sha256_bytes(f.read_bytes())
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            csv = obj
        elif obj["kind"] == "CustomResourceDefinition":
            crds.append((f.name, obj))
        else:
            others.append(obj)
    if csv is None:
        raise SystemExit(f"{name}: no CSV in {root}/manifests")
    return fetch["image"], csv, crds, others, inputs


def clean(obj):
    obj = copy.deepcopy(obj)
    obj.get("metadata", {}).pop("creationTimestamp", None)
    obj.pop("status", None)
    return obj


def with_namespace(obj):
    if obj["kind"] in NAMESPACED_KINDS:
        obj.setdefault("metadata", {})["namespace"] = NAMESPACE_PLACEHOLDER
    return obj


def rewrite_subjects(obj, mods):
    for s in obj.get("subjects", []) or []:
        if s.get("kind") == "ServiceAccount" and s.get("namespace") in PLACEHOLDER_NAMESPACES:
            mods.append(f"{obj['kind']}/{obj['metadata']['name']}: subject namespace {s['namespace']} -> install namespace")
            s["namespace"] = NAMESPACE_PLACEHOLDER
    return obj


def deployments(csv, comp, mods):
    out = []
    for d in csv["spec"]["install"]["spec"]["deployments"]:
        dep = {"apiVersion": "apps/v1", "kind": "Deployment",
               "metadata": {"name": d["name"], "namespace": NAMESPACE_PLACEHOLDER, "labels": d.get("label", {})},
               "spec": copy.deepcopy(d["spec"])}
        if d["name"] == comp["webhook_deployment"]:
            secret = f"{comp['prefix']}-webhook-server-cert"
            pod = dep["spec"]["template"]["spec"]
            pod.setdefault("volumes", []).append({"name": "webhook-server-cert", "secret": {"secretName": secret, "defaultMode": 420}})
            manager = next(c for c in pod["containers"] if c["name"] == "manager")
            manager.setdefault("volumeMounts", []).append({"name": "webhook-server-cert", "mountPath": WEBHOOK_CERT_DIR, "readOnly": True})
            mods.append(f"Deployment/{d['name']}: added service-ca webhook certificate volume {secret} at {WEBHOOK_CERT_DIR}")
        out.append(dep)
    return out


def rbac(csv, comp, mods):
    spec = csv["spec"]["install"]["spec"]
    out, sas = [], set()
    for p in spec.get("permissions", []) or []:
        sa = p["serviceAccountName"]; sas.add(sa)
        subjects = [{"kind": "ServiceAccount", "name": sa, "namespace": NAMESPACE_PLACEHOLDER}]
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                    "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER}, "rules": p["rules"]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding",
                    "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": sa},
                    "subjects": copy.deepcopy(subjects)})
        # OLM's OperatorGroup controller (ensureSingletonRBAC) also grants a CSV's namespaced permissions
        # cluster-wide when the OperatorGroup targets all namespaces, the only install mode these CSVs
        # support. Reproduce that copy; the suffix keeps it apart from the clusterPermissions role named after the SA.
        # OLM also appends get/list/watch on namespaces to that copy (NMO needs it to sync its cache for
        # the medik8s-leases Namespace), so the copy is the CSV rules followed by OLM_NAMESPACES_RULE.
        cluster_name = f"{sa}{ALL_NAMESPACES_SUFFIX}"
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
                    "metadata": {"name": cluster_name}, "rules": copy.deepcopy(p["rules"]) + [copy.deepcopy(OLM_NAMESPACES_RULE)]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": cluster_name},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": cluster_name},
                    "subjects": copy.deepcopy(subjects)})
        mods.append(f"CSV permissions for {sa} also rendered as ClusterRole/ClusterRoleBinding {cluster_name}, "
                    "as OLM grants them for an AllNamespaces OperatorGroup, "
                    "plus OLM's appended get/list/watch rule on namespaces")
    for p in spec.get("clusterPermissions", []) or []:
        sa = p["serviceAccountName"]; sas.add(sa)
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": sa}, "rules": p["rules"]})
        out.append({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": sa},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": sa},
                    "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": NAMESPACE_PLACEHOLDER}]})
    for d in spec["deployments"]:
        sas.add(d["spec"]["template"]["spec"]["serviceAccountName"])
    for sa in sorted(sas):
        obj = {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": sa, "namespace": NAMESPACE_PLACEHOLDER}}
        if sa in comp.get("automount_disabled", []):
            obj["automountServiceAccountToken"] = False
            mods.append(f"ServiceAccount/{sa}: automountServiceAccountToken=false, as upstream's service_account.yaml sets it")
        out.append(obj)
    mods.append("CSV permissions/clusterPermissions rendered as Role/RoleBinding/ClusterRole/ClusterRoleBinding named after each ServiceAccount")
    return out


def webhooks(csv, comp, mods):
    defs = csv["spec"].get("webhookdefinitions") or []
    groups = {"ValidatingAdmissionWebhook": ("ValidatingWebhookConfiguration", "validating"),
              "MutatingAdmissionWebhook": ("MutatingWebhookConfiguration", "mutating")}
    out = []
    for wtype, (kind, suffix) in groups.items():
        hooks = []
        for w in defs:
            if w["type"] != wtype:
                continue
            if w["deploymentName"] != comp["webhook_deployment"]:
                raise SystemExit(f"webhook {w['generateName']} targets unexpected deployment {w['deploymentName']}")
            hook = {"name": w["generateName"], "admissionReviewVersions": w["admissionReviewVersions"],
                    "sideEffects": w["sideEffects"], "failurePolicy": w["failurePolicy"], "rules": w["rules"],
                    "clientConfig": {"service": {"name": comp["webhook_service"], "namespace": NAMESPACE_PLACEHOLDER,
                                                 "path": w["webhookPath"], "port": w.get("containerPort", 443)}}}
            # Optional fields OLM would also carry over from the webhook definition (e.g. NMO's timeoutSeconds).
            for field in OPTIONAL_WEBHOOK_FIELDS[kind]:
                if field in w:
                    hook[field] = copy.deepcopy(w[field])
            hooks.append(hook)
        if hooks:
            out.append({"apiVersion": "admissionregistration.k8s.io/v1", "kind": kind,
                        "metadata": {"name": f"{comp['prefix']}-{suffix}-webhook-configuration",
                                     "annotations": {INJECT_CABUNDLE_ANNOTATION: "true"}},
                        "webhooks": sorted(hooks, key=lambda h: h["name"])})
            mods.append(f"{kind}: generated from CSV webhookdefinitions with service-ca CA bundle injection")
    return out


def other_objects(others, comp, mods):
    out = []
    for obj in others:
        obj = with_namespace(clean(obj))
        rewrite_subjects(obj, mods)
        if comp["webhook_service"] and obj["kind"] == "Service" and obj["metadata"]["name"] == comp["webhook_service"]:
            obj["metadata"].setdefault("annotations", {})[SERVING_CERT_ANNOTATION] = f"{comp['prefix']}-webhook-server-cert"
            mods.append(f"Service/{obj['metadata']['name']}: added {SERVING_CERT_ANNOTATION}")
        out.append(obj)
    return out


def matches(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


def isolate(rendered):
    """Cross-component pass (D10). rendered: {component: (objects, mods)}; mutates in place."""
    pod_labels = {}
    for name, (objects, mods) in rendered.items():
        key = COMPONENTS[name]["key"]
        for o in objects:
            if o["kind"] == "Deployment":
                labels = o["spec"]["template"]["metadata"].setdefault("labels", {})
                labels[COMPONENT_LABEL] = key
                pod_labels.setdefault(name, []).append(labels)
                mods.append(f"Deployment/{o['metadata']['name']}: pod template labeled {COMPONENT_LABEL}={key}")
    for name, (objects, mods) in rendered.items():
        key = COMPONENTS[name]["key"]
        for o in objects:
            if o["kind"] != "Service":
                continue
            selector = o["spec"].get("selector") or {}
            foreign = sorted(other for other, labels in pod_labels.items()
                             if other != name and any(matches(selector, l) for l in labels))
            if foreign:
                selector[COMPONENT_LABEL] = key
                mods.append(f"Service/{o['metadata']['name']}: selector narrowed with {COMPONENT_LABEL}={key}; it also matched {', '.join(foreign)} pods")
    seen = {}
    for name, (objects, _) in rendered.items():
        for o in objects:
            ident = (o["kind"], o["metadata"].get("namespace", ""), o["metadata"]["name"])
            if ident in seen:
                raise SystemExit(f"{ident} is produced by both {seen[ident]} and {name}")
            seen[ident] = name


def check_images(name, files, release_set):
    """Every image reference in the output must be an upstream reference listed in release-set.yaml."""
    known = {img["upstream"] for img in release_set["components"][name]["images"].values()}
    found = set()
    for text in files.values():
        for line in text.splitlines():
            s = line.strip().removeprefix("- ")
            for key in ("image: ", "value: "):
                if s.startswith(key) and "quay.io/" in s:
                    found.add(s[len(key):].strip("'\""))
    unknown = sorted(found - known)
    if unknown:
        raise SystemExit(f"{name}: images not listed in release-set.yaml: {unknown}")
    missing = sorted(known - found)
    if missing:
        raise SystemExit(f"{name}: release-set.yaml images not referenced by the bundle: {missing}")


def filename(obj):
    return f"{ORDER[obj['kind']]}-{obj['kind']}-{obj['metadata']['name']}.yaml"


def write_tree(target, files, check, ignore_extra=False):
    target = pathlib.Path(target)
    if not check:
        target.mkdir(parents=True, exist_ok=True)
        if not ignore_extra:
            for stale in target.glob("*.yaml"):
                stale.unlink()
    problems = []
    for name, text in files.items():
        p = target / name
        if check:
            if not p.exists() or p.read_text() != text:
                problems.append(str(p))
        else:
            p.write_text(text)
    if check and not ignore_extra:
        problems.extend(sorted(str(p) for p in target.glob("*.yaml") if p.name not in files))
    return problems


def union_role(rendered):
    """Every rule of every Role/ClusterRole WAO renders (CSV permissions and bundle-shipped roles alike):
    RBAC escalation prevention only lets WAO create a role whose rules it holds itself (D7)."""
    seen, rules = set(), []
    for name in sorted(rendered):
        for o in rendered[name][0]:
            if o["kind"] not in ("Role", "ClusterRole"):
                continue
            for r in o.get("rules") or []:
                key = json.dumps(r, sort_keys=True)
                if key not in seen:
                    seen.add(key); rules.append(r)
    for r in WAO_OWN_RULES:
        key = json.dumps(r, sort_keys=True)
        if key not in seen:
            seen.add(key); rules.append(r)
    rules.sort(key=lambda r: json.dumps(r, sort_keys=True))
    role = {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "operand-union-role"}, "rules": rules}
    binding = {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "operand-union-rolebinding"},
               "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "operand-union-role"},
               "subjects": [{"kind": "ServiceAccount", "name": "controller-manager", "namespace": "system"}]}
    return "---\n".join(dump(x) for x in (role, binding))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundles", required=True, help=".cache/bundles")
    ap.add_argument("--release-set", required=True)
    ap.add_argument("--out", required=True, help="internal/operands/manifests")
    ap.add_argument("--crd-out", required=True, help="config/crd/bases")
    ap.add_argument("--rbac-out", required=True, help="config/rbac/operand_union_role.yaml")
    ap.add_argument("--check", action="store_true", help="verify outputs are current instead of writing")
    args = ap.parse_args()
    release_set = yaml.safe_load(pathlib.Path(args.release_set).read_text())

    provenance = {"generator": "hack/extract-operand-manifests.py", "namespace_placeholder": NAMESPACE_PLACEHOLDER, "bundles": {}}
    crd_files, problems, rendered, meta = {}, [], {}, {}
    for name, comp in COMPONENTS.items():
        bundle_ref, csv, crds, others, inputs = load_bundle(args.bundles, name)
        if bundle_ref != release_set["components"][name]["bundle"]:
            raise SystemExit(f"{name}: cached bundle {bundle_ref} does not match release-set.yaml; run `make bundles`")
        mods = []
        objects = rbac(csv, comp, mods) + other_objects(others, comp, mods) + deployments(csv, comp, mods) + webhooks(csv, comp, mods)
        rendered[name] = (objects, mods)
        meta[name] = (bundle_ref, csv["metadata"]["name"], inputs, crds)
        for crd_name, crd in crds:
            crd_files[crd_name] = dump(clean(crd))
    isolate(rendered)
    for name, (objects, mods) in rendered.items():
        files = {filename(o): dump(o) for o in objects}
        if len(files) != len(objects):
            raise SystemExit(f"{name}: duplicate output filenames")
        check_images(name, files, release_set)
        problems += write_tree(pathlib.Path(args.out) / name, files, args.check)
        bundle_ref, csv_name, inputs, crds = meta[name]
        provenance["bundles"][name] = {
            "bundle": bundle_ref, "csv": csv_name, "inputs": inputs,
            "outputs": {f"{name}/{fn}": sha256_bytes(text.encode()) for fn, text in sorted(files.items())},
            "crds": [c for c, _ in crds], "wao_modifications": sorted(set(mods)),
        }
    # The CRD directory also holds the controller-gen CRD for WorkloadAvailabilityConfig; never delete or flag it.
    problems += write_tree(args.crd_out, crd_files, args.check, ignore_extra=True)
    union = union_role(rendered)
    prov_text = json.dumps(provenance, indent=2, sort_keys=True) + "\n"
    if args.check:
        if pathlib.Path(args.rbac_out).read_text() != union:
            problems.append(args.rbac_out)
        if (pathlib.Path(args.out) / "provenance.json").read_text() != prov_text:
            problems.append(str(pathlib.Path(args.out) / "provenance.json"))
        if problems:
            print("STALE OUTPUTS:\n" + "\n".join(problems)); sys.exit(1)
        print("outputs current")
        return
    pathlib.Path(args.rbac_out).write_text(union)
    (pathlib.Path(args.out) / "provenance.json").write_text(prov_text)
    print(f"wrote {sum(len(b['outputs']) for b in provenance['bundles'].values())} manifests, {len(crd_files)} CRDs, union role")


if __name__ == "__main__":
    main()
