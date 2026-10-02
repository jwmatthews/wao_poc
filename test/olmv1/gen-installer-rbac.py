#!/usr/bin/env python3
"""Generate OLM v1 installer RBAC and ClusterExtension manifests for the six RHWA operators.

For each operator (nhc, snr, far, mdr, nmo, sbr) this script reads the shipped CSV
(plus the other objects in the bundle, when a bundle directory is available) and emits:

    rbac/<key>/00-serviceaccount.yaml      ServiceAccount <key>-installer
    rbac/<key>/10-clusterrole.yaml         ClusterRole    <key>-installer-clusterrole
    rbac/<key>/20-clusterrolebinding.yaml  ClusterRoleBinding <key>-installer-binding
    rbac/<key>/30-clusterextension.yaml    ClusterExtension <package>
    rbac/<key>/kustomization.yaml

The ClusterRole follows the structure of the OpenShift 4.22 procedure "Creating a cluster
role for an extension" (olmv1-creating-a-cluster-role.adoc): finalizers rule scoped to the
extension name, ClusterRole/ClusterRoleBinding management, CRDs scoped to the owned CRD
names, the union of the CSV permissions/clusterPermissions, Deployments, Services and
ConfigMaps, plus the extra groups this experiment needs (ServiceAccounts, Secrets, Roles,
RoleBindings, webhook configurations, and every other object kind shipped in the bundle).

Facts about what OLM v1 actually renders from a registry+v1 bundle are taken from
operator-controller's internal/operator-controller/rukpak/render/registryv1/generators
(see README.md next to the output).

These manifests are experiment inputs, not product RBAC. Nothing here touches a cluster.

Usage:
    .venv/bin/python test/olmv1/gen-installer-rbac.py [--out test/olmv1/rbac]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

INSTALL_NAMESPACE = "openshift-workload-availability"
CATALOG_NAME = "openshift-redhat-operators"
CHANNEL = "stable"
DEFAULT_OUT = os.path.join(HERE, "rbac")

CSV_DIR = os.path.join(REPO, "evidence", "2026-10-02-olmv1-0001", "csv-downstream")
BUNDLES_DIR = os.path.join(REPO, ".cache", "bundles")

# Catalog facts (openshift-redhat-operators, channel stable, heads as of 2026-10-02).
OPERATORS: list[dict[str, Any]] = [
    {
        "key": "nhc",
        "package": "node-healthcheck-operator",
        "head": "0.12.1",
        "csv": os.path.join(CSV_DIR, "node-healthcheck-operator.v0.12.1.json"),
        "bundle": os.path.join(BUNDLES_DIR, "nhc", "manifests"),
        # The downstream (OCP flavour) NHC bundle ships the node-remediation console plugin:
        # its Deployment and ServiceAccount show up in the catalog CSV, but the Service that
        # fronts it (the plugin Deployment mounts the service-ca secret `nrc-plugin-cert`)
        # is a non-CSV bundle object we cannot see offline. Its name is fixed in
        # node-healthcheck-operator internal/controller/console/plugin.go (ServiceName).
        "extra_services": ["node-healthcheck-node-remediation-console-plugin"],
    },
    {
        "key": "snr",
        "package": "self-node-remediation",
        "head": "0.13.1",
        "csv": os.path.join(CSV_DIR, "self-node-remediation.v0.13.1.json"),
        "bundle": os.path.join(BUNDLES_DIR, "snr", "manifests"),
    },
    {
        "key": "far",
        "package": "fence-agents-remediation",
        "head": "0.8.1",
        "csv": os.path.join(CSV_DIR, "fence-agents-remediation.v0.8.1.json"),
        "bundle": os.path.join(BUNDLES_DIR, "far", "manifests"),
    },
    {
        "key": "mdr",
        "package": "machine-deletion-remediation",
        "head": "0.7.1",
        "csv": os.path.join(CSV_DIR, "machine-deletion-remediation.v0.7.1.json"),
        "bundle": os.path.join(BUNDLES_DIR, "mdr", "manifests"),
    },
    {
        "key": "nmo",
        "package": "node-maintenance-operator",
        "head": "5.7.1",
        "csv": os.path.join(CSV_DIR, "node-maintenance-operator.v5.7.1.json"),
        "bundle": os.path.join(BUNDLES_DIR, "nmo", "manifests"),
    },
    {
        "key": "sbr",
        "package": "storage-based-remediation",
        "head": "0.3.1",
        # Downstream SBR 0.3.1 CSV is not in the evidence set; the upstream 0.3.0 bundle has
        # the same RBAC shape (only image references differ).
        "csv": os.path.join(BUNDLES_DIR, "sbr", "manifests", "storage-based-remediation.clusterserviceversion.yaml"),
        "bundle": os.path.join(BUNDLES_DIR, "sbr", "manifests"),
    },
]

# Kind -> (apiGroup, plural resource, namespaced) for objects that may appear in a
# registry+v1 bundle beside the CSV and CRDs. OLM v1 sets the namespace of namespaced
# objects to the install namespace (BundleAdditionalResourcesGenerator).
KIND_MAP: dict[str, tuple[str, str, bool]] = {
    "Secret": ("", "secrets", True),
    "ConfigMap": ("", "configmaps", True),
    "Service": ("", "services", True),
    "ServiceAccount": ("", "serviceaccounts", True),
    "Role": ("rbac.authorization.k8s.io", "roles", True),
    "RoleBinding": ("rbac.authorization.k8s.io", "rolebindings", True),
    "ClusterRole": ("rbac.authorization.k8s.io", "clusterroles", False),
    "ClusterRoleBinding": ("rbac.authorization.k8s.io", "clusterrolebindings", False),
    "SecurityContextConstraints": ("security.openshift.io", "securitycontextconstraints", False),
    "ConsolePlugin": ("console.openshift.io", "consoleplugins", False),
    "ConsoleLink": ("console.openshift.io", "consolelinks", False),
    "ConsoleYAMLSample": ("console.openshift.io", "consoleyamlsamples", False),
    "ConsoleQuickStart": ("console.openshift.io", "consolequickstarts", False),
    "PrometheusRule": ("monitoring.coreos.com", "prometheusrules", True),
    "ServiceMonitor": ("monitoring.coreos.com", "servicemonitors", True),
    "PodDisruptionBudget": ("policy", "poddisruptionbudgets", True),
    "PriorityClass": ("scheduling.k8s.io", "priorityclasses", False),
    "NetworkPolicy": ("networking.k8s.io", "networkpolicies", True),
    "VerticalPodAutoscaler": ("autoscaling.k8s.io", "verticalpodautoscalers", True),
}

CREATE_VERBS = ["create", "list", "watch"]
MANAGE_VERBS = ["get", "update", "patch", "delete"]
ALL_VERBS = ["get", "list", "watch", "create", "update", "patch", "delete"]


# --------------------------------------------------------------------------- helpers
def load_yaml_or_json(path: str) -> Any:
    with open(path, encoding="utf-8") as fh:
        if path.endswith(".json"):
            return json.load(fh)
        return yaml.safe_load(fh)


def rule(api_groups: list[str], resources: list[str], verbs: list[str],
         resource_names: list[str] | None = None) -> dict[str, Any]:
    r: dict[str, Any] = {"apiGroups": list(api_groups), "resources": list(resources), "verbs": list(verbs)}
    if resource_names:
        r["resourceNames"] = sorted(set(resource_names))
    return r


def normalize_rule(r: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of a CSV PolicyRule with keys in a stable order (unknown keys kept)."""
    out: dict[str, Any] = {}
    for k in ("apiGroups", "resources", "verbs", "resourceNames", "nonResourceURLs"):
        if k in r and r[k] is not None:
            out[k] = list(r[k])
    for k, v in r.items():
        if k not in out and v is not None:
            out[k] = v
    return out


def rule_key(r: dict[str, Any]) -> str:
    return json.dumps({k: sorted(v) if isinstance(v, list) else v for k, v in r.items()}, sort_keys=True)


class Group:
    """A commented block of rules in the generated ClusterRole."""

    def __init__(self, title: str, source: str, rules: list[dict[str, Any]],
                 unscoped_reason: str | None = None, notes: list[str] | None = None):
        self.title = title
        self.source = source
        self.rules = rules
        self.unscoped_reason = unscoped_reason  # None => every manage rule is scoped
        self.notes = notes or []


# --------------------------------------------------------------------------- parsing
def parse_csv(csv: dict[str, Any]) -> dict[str, Any]:
    spec = csv["spec"]
    strategy = spec["install"]["spec"]
    owned_crds = sorted(c["name"] for c in spec.get("customresourcedefinitions", {}).get("owned", []))
    deployments = [d["name"] for d in strategy.get("deployments", [])]
    permissions = [{"serviceAccountName": p.get("serviceAccountName") or "default",
                    "rules": [normalize_rule(r) for r in p.get("rules", [])]}
                   for p in strategy.get("permissions", [])]
    cluster_permissions = [{"serviceAccountName": p.get("serviceAccountName") or "default",
                            "rules": [normalize_rule(r) for r in p.get("rules", [])]}
                           for p in strategy.get("clusterPermissions", [])]
    webhooks = [{"type": w.get("type"), "generateName": w.get("generateName"),
                 "deploymentName": w.get("deploymentName")}
                for w in spec.get("webhookdefinitions", [])]
    service_accounts = sorted({p["serviceAccountName"] for p in permissions + cluster_permissions})
    for d in strategy.get("deployments", []):
        sa = d["spec"]["template"]["spec"].get("serviceAccountName")
        if sa and sa not in service_accounts:
            service_accounts.append(sa)
    return {
        "name": csv["metadata"]["name"],
        "owned_crds": owned_crds,
        "deployments": deployments,
        "permissions": permissions,
        "cluster_permissions": cluster_permissions,
        "webhooks": webhooks,
        "service_accounts": sorted(service_accounts),
    }


def load_bundle_objects(bundle_dir: str | None) -> list[dict[str, Any]]:
    """Every object in the bundle manifests dir except the CSV and CRDs."""
    objs: list[dict[str, Any]] = []
    if not bundle_dir or not os.path.isdir(bundle_dir):
        return objs
    for fn in sorted(os.listdir(bundle_dir)):
        if not fn.endswith((".yaml", ".yml", ".json")):
            continue
        with open(os.path.join(bundle_dir, fn), encoding="utf-8") as fh:
            docs = list(yaml.safe_load_all(fh))
        for doc in docs:
            if not doc or doc.get("kind") in ("ClusterServiceVersion", "CustomResourceDefinition"):
                continue
            objs.append(doc)
    return objs


def webhook_service_name(deployment_name: str) -> str:
    # render.CertProvisionerFor: util.ObjectNameForBaseAndSuffix(strings.ReplaceAll(dep, ".", "-"), "service")
    return deployment_name.replace(".", "-") + "-service"


# --------------------------------------------------------------------------- rule building
def build_groups(op: dict[str, Any], info: dict[str, Any], others: list[dict[str, Any]]) -> list[Group]:
    ext_name = op["package"]
    groups: list[Group] = []

    # 1. Finalizers on the ClusterExtension (OwnerReferencesPermissionEnforcement).
    groups.append(Group(
        "ClusterExtension finalizers",
        "docs: olmv1-creating-a-cluster-role.adoc step 2 (scoped to the ClusterExtension metadata.name)",
        [rule(["olm.operatorframework.io"], ["clusterextensions/finalizers"], ["update"], [ext_name])],
    ))

    # 2. ClusterRoles / ClusterRoleBindings for the controllers (+ bundle-shipped ones).
    bundle_crs = sorted(o["metadata"]["name"] for o in others if o["kind"] == "ClusterRole")
    bundle_crbs = sorted(o["metadata"]["name"] for o in others if o["kind"] == "ClusterRoleBinding")
    notes = [
        "OLM v1 names the ClusterRole/ClusterRoleBinding it renders from clusterPermissions",
        f"'{info['name']}-<serviceAccount>-<hash>' (render.DefaultUniqueNameGenerator hashes the",
        "PolicyRule set), so the names cannot be known before the first install. The docs' example",
        "'resourceNames: [\"*\"]' is only a placeholder: RBAC resourceNames have no wildcard, so the",
        "manage rule is left UNSCOPED here. Tighten after the first install with the real names.",
    ]
    if bundle_crs:
        notes.append("Also covers the bundle-shipped ClusterRoles: " + ", ".join(bundle_crs))
    if bundle_crbs:
        notes.append("Also covers the bundle-shipped ClusterRoleBindings: " + ", ".join(bundle_crbs))
    groups.append(Group(
        "ClusterRoles and ClusterRoleBindings for the controllers of the extension",
        "docs: olmv1-creating-a-cluster-role.adoc step 3; CSV clusterPermissions; bundle ClusterRole/ClusterRoleBinding objects",
        [
            rule(["rbac.authorization.k8s.io"], ["clusterroles"], CREATE_VERBS),
            rule(["rbac.authorization.k8s.io"], ["clusterroles"], MANAGE_VERBS),
            rule(["rbac.authorization.k8s.io"], ["clusterrolebindings"], CREATE_VERBS),
            rule(["rbac.authorization.k8s.io"], ["clusterrolebindings"], MANAGE_VERBS),
        ],
        unscoped_reason="generated names <csv>-<sa>-<hash> unknown before install; resourceNames has no wildcard",
        notes=notes,
    ))

    # 2b. escalate / bind.
    groups.append(Group(
        "Privilege-escalation guards: escalate and bind",
        "docs: olmv1-troubleshooting-rbac-errors-with-preflight-check.adoc ('Privilege escalation'); task requirement",
        [
            rule(["rbac.authorization.k8s.io"], ["clusterroles", "roles"], ["escalate"]),
            rule(["rbac.authorization.k8s.io"], ["clusterrolebindings", "rolebindings"], ["bind"]),
        ],
        unscoped_reason="role names are generated; the union of granted rules below is still carried so escalate/bind are belt-and-braces",
        notes=[
            "The installer carries the union of every rule it grants (below), which already satisfies",
            "the RBAC escalation check; escalate/bind keep the install working if a future bundle",
            "revision adds a rule this ClusterRole was not regenerated for.",
        ],
    ))

    # 3. CRDs.
    groups.append(Group(
        "Custom resource definitions of the extension",
        "docs: olmv1-creating-a-cluster-role.adoc step 4; CSV spec.customresourcedefinitions.owned",
        [
            rule(["apiextensions.k8s.io"], ["customresourcedefinitions"], CREATE_VERBS),
            rule(["apiextensions.k8s.io"], ["customresourcedefinitions"], MANAGE_VERBS, info["owned_crds"]),
        ],
    ))

    # 4. Union of permissions + clusterPermissions (+ bundle Role/ClusterRole rules).
    seen: set[str] = set()

    def add_unique(dst: list[dict[str, Any]], r: dict[str, Any]) -> None:
        k = rule_key(r)
        if k not in seen:
            seen.add(k)
            dst.append(r)

    for section in ("permissions", "cluster_permissions"):
        for perm in info[section]:
            rules: list[dict[str, Any]] = []
            for r in perm["rules"]:
                add_unique(rules, r)
            label = "install.spec.permissions" if section == "permissions" else "install.spec.clusterPermissions"
            if rules:
                groups.append(Group(
                    f"Excerpt from {label} (serviceAccountName: {perm['serviceAccountName']})",
                    f"docs: olmv1-creating-a-cluster-role.adoc step 5; CSV {label}[serviceAccountName={perm['serviceAccountName']}]",
                    rules,
                ))
    if info["permissions"]:
        promo = [rule([""], ["namespaces"], ["get", "list", "watch"])]
        rules = []
        for r in promo:
            add_unique(rules, r)
        groups.append(Group(
            "AllNamespaces promotion of install.spec.permissions",
            "operator-controller BundleCSVClusterPermissionsGenerator: in AllNamespaces mode each permissions entry is promoted to a ClusterRole with an extra namespaces get/list/watch rule",
            rules,
            notes=[] if rules else ["(already covered by a rule above)"],
        ))
        if not rules:
            groups.pop()
    for o in others:
        if o["kind"] in ("ClusterRole", "Role") and o.get("rules"):
            rules = []
            for r in o["rules"]:
                add_unique(rules, normalize_rule(r))
            if rules:
                groups.append(Group(
                    f"Rules of bundle-shipped {o['kind']} {o['metadata']['name']} (the installer must hold what it grants)",
                    f"bundle object {o['kind']}/{o['metadata']['name']}",
                    rules,
                ))

    # 5. Deployments.
    groups.append(Group(
        "Excerpt from install.spec.deployments",
        "docs: olmv1-creating-a-cluster-role.adoc step 6; CSV install.spec.deployments[].name",
        [
            rule(["apps"], ["deployments"], CREATE_VERBS),
            rule(["apps"], ["deployments"], MANAGE_VERBS, info["deployments"]),
        ],
    ))

    # 6. ServiceAccounts.
    sa_names = list(info["service_accounts"])
    sa_names += [o["metadata"]["name"] for o in others if o["kind"] == "ServiceAccount"]
    sa_names = sorted({n for n in sa_names if n != "default"})
    groups.append(Group(
        "ServiceAccounts for the extension controllers",
        "docs: olmv1-required-rbac...adoc 'Service accounts'; CSV permissions/clusterPermissions serviceAccountName, deployments serviceAccountName, bundle ServiceAccount objects",
        [
            rule([""], ["serviceaccounts"], CREATE_VERBS),
            rule([""], ["serviceaccounts"], MANAGE_VERBS, sa_names),
        ],
    ))

    # 7. Services.
    svc_names = sorted({webhook_service_name(w["deploymentName"]) for w in info["webhooks"] if w.get("deploymentName")})
    bundle_svcs = sorted(o["metadata"]["name"] for o in others if o["kind"] == "Service")
    extra_svcs = list(op.get("extra_services", []))
    all_svcs = sorted(set(svc_names + bundle_svcs + extra_svcs))
    svc_notes = []
    if svc_names:
        svc_notes.append("webhook Services rendered by OLM v1 (<deployment>-service): " + ", ".join(svc_names))
    if bundle_svcs:
        svc_notes.append("bundle-shipped Services: " + ", ".join(bundle_svcs))
    if extra_svcs:
        svc_notes.append("expected downstream-only Services (not visible offline): " + ", ".join(extra_svcs))
    svc_notes.append("docs step 7 puts list/watch under resourceNames; moved to the unscoped rule because the preflight "
                     "report in olmv1-troubleshooting-rbac-errors-with-preflight-check.adoc asks for cluster-wide "
                     "services list,watch and a name-scoped rule cannot satisfy that")
    groups.append(Group(
        "Services",
        "docs: olmv1-creating-a-cluster-role.adoc step 7; operator-controller BundleDeploymentServiceResourceGenerator (webhooks); bundle Service objects",
        [
            rule([""], ["services"], CREATE_VERBS),
            rule([""], ["services"], MANAGE_VERBS, all_svcs) if all_svcs else rule([""], ["services"], MANAGE_VERBS),
        ],
        unscoped_reason=None if all_svcs else "no Service names known",
        notes=svc_notes,
    ))

    # 8. ConfigMaps and Secrets (namespace-scoped bundle resources + experiment slack).
    cm_names = sorted(o["metadata"]["name"] for o in others if o["kind"] == "ConfigMap")
    cm_rules = [rule([""], ["configmaps"], CREATE_VERBS)]
    if cm_names:
        cm_rules.append(rule([""], ["configmaps"], MANAGE_VERBS, cm_names))
        cm_reason = None
    else:
        cm_rules.append(rule([""], ["configmaps"], MANAGE_VERBS))
        cm_reason = "no ConfigMap in the bundle; kept unscoped so the preflight check (Technology Preview) cannot fail on a downstream-only object"
    groups.append(Group(
        "ConfigMaps",
        "docs: olmv1-creating-a-cluster-role.adoc step 7 (list/watch moved to the unscoped rule, see Services); bundle ConfigMap objects",
        cm_rules,
        unscoped_reason=cm_reason,
        notes=["bundle-shipped ConfigMaps: " + ", ".join(cm_names)] if cm_names else [],
    ))
    groups.append(Group(
        "Secrets (experiment-only breadth)",
        "task requirement; no bundle ships a Secret; serving-cert Secrets are created by service-ca, not by the installer",
        [rule([""], ["secrets"], ALL_VERBS)],
        unscoped_reason="no Secret is rendered by OLM v1 for these bundles; granted cluster-wide only so the experiment never stalls on a Secret the downstream bundle might add",
    ))

    # 9. Roles / RoleBindings.
    groups.append(Group(
        "Roles and RoleBindings (only rendered when the extension is installed with a watchNamespace; in AllNamespaces mode permissions are promoted to ClusterRoles)",
        "docs: olmv1-required-rbac...adoc 'Roles and role bindings'; CSV install.spec.permissions",
        [
            rule(["rbac.authorization.k8s.io"], ["roles", "rolebindings"], CREATE_VERBS),
            rule(["rbac.authorization.k8s.io"], ["roles", "rolebindings"], MANAGE_VERBS),
        ],
        unscoped_reason="generated names <csv>-<sa>-<hash> unknown before install",
    ))

    # 10. Webhook configurations.
    vwh = sorted((w["generateName"] or "").rstrip("-") for w in info["webhooks"] if w["type"] == "ValidatingAdmissionWebhook")
    mwh = sorted((w["generateName"] or "").rstrip("-") for w in info["webhooks"] if w["type"] == "MutatingAdmissionWebhook")
    if info["webhooks"]:
        wh_rules = []
        if vwh:
            wh_rules.append(rule(["admissionregistration.k8s.io"], ["validatingwebhookconfigurations"], ALL_VERBS))
        if mwh:
            wh_rules.append(rule(["admissionregistration.k8s.io"], ["mutatingwebhookconfigurations"], ALL_VERBS))
        wh_notes = []
        if vwh:
            wh_notes.append("ValidatingWebhookConfiguration names OLM v1 derives from webhookdefinitions[].generateName: " + ", ".join(vwh))
        if mwh:
            wh_notes.append("MutatingWebhookConfiguration names OLM v1 derives from webhookdefinitions[].generateName: " + ", ".join(mwh))
        groups.append(Group(
            "Admission webhook configurations",
            "CSV spec.webhookdefinitions; operator-controller Bundle{Validating,Mutating}WebhookResourceGenerator",
            wh_rules,
            unscoped_reason="names are generated by OLM v1 from the CSV (generateName with trailing '-' trimmed); left unscoped per experiment brief, expected names listed in the comment",
            notes=wh_notes,
        ))

    # 11. Anything else in the bundle not already covered above.
    covered = {"ClusterRole", "ClusterRoleBinding", "ServiceAccount", "Service", "ConfigMap", "Secret", "Role", "RoleBinding"}
    by_kind: dict[str, list[str]] = {}
    for o in others:
        if o["kind"] in covered:
            continue
        by_kind.setdefault(o["kind"], []).append(o["metadata"]["name"])
    for kind, names in sorted(by_kind.items()):
        if kind not in KIND_MAP:
            raise SystemExit(f"{op['key']}: bundle ships unsupported kind {kind}; extend KIND_MAP")
        group, resource, _ = KIND_MAP[kind]
        groups.append(Group(
            f"Bundle-shipped {kind} objects",
            f"bundle objects of kind {kind}",
            [
                rule([group], [resource], CREATE_VERBS),
                rule([group], [resource], MANAGE_VERBS, sorted(names)),
            ],
        ))

    return groups


# --------------------------------------------------------------------------- rendering
def dump(obj: Any) -> str:
    return yaml.safe_dump(obj, sort_keys=False, default_flow_style=False, width=1000)


def render_clusterrole(op: dict[str, Any], info: dict[str, Any], groups: list[Group], csv_path: str, bundle_dir: str) -> str:
    out = [
        "# Generated by test/olmv1/gen-installer-rbac.py -- DO NOT EDIT BY HAND; regenerate instead.",
        f"# Operator: {op['key']} (package {op['package']}, CSV {info['name']}, catalog head {op['head']})",
        f"# CSV input: {os.path.relpath(csv_path, REPO)}",
        f"# Bundle objects input: {os.path.relpath(bundle_dir, REPO) if bundle_dir else '(none)'}",
        "# Experiment input only: deliberately broad in the places marked UNSCOPED. Not product RBAC.",
        "apiVersion: rbac.authorization.k8s.io/v1",
        "kind: ClusterRole",
        "metadata:",
        f"  name: {op['key']}-installer-clusterrole",
        "rules:",
    ]
    for g in groups:
        out.append(f"# --- {g.title}")
        out.append(f"#     source: {g.source}")
        if g.unscoped_reason:
            out.append(f"#     UNSCOPED: {g.unscoped_reason}")
        for n in g.notes:
            out.append(f"#     note: {n}")
        out.append(dump(g.rules).rstrip("\n"))
    return "\n".join(out) + "\n"


def render_serviceaccount(op: dict[str, Any]) -> str:
    return "# Generated by test/olmv1/gen-installer-rbac.py (docs: olmv1-creating-a-service-account.adoc)\n" + dump({
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {"name": f"{op['key']}-installer", "namespace": INSTALL_NAMESPACE},
    })


def render_clusterrolebinding(op: dict[str, Any]) -> str:
    return "# Generated by test/olmv1/gen-installer-rbac.py (docs: olmv1-creating-a-cluster-role-binding.adoc)\n" + dump({
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRoleBinding",
        "metadata": {"name": f"{op['key']}-installer-binding"},
        "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole",
                    "name": f"{op['key']}-installer-clusterrole"},
        "subjects": [{"kind": "ServiceAccount", "name": f"{op['key']}-installer", "namespace": INSTALL_NAMESPACE}],
    })


def clusterextension_object(op: dict[str, Any]) -> dict[str, Any]:
    return {
        "apiVersion": "olm.operatorframework.io/v1",
        "kind": "ClusterExtension",
        "metadata": {"name": op["package"]},
        "spec": {
            "namespace": INSTALL_NAMESPACE,
            "serviceAccount": {"name": f"{op['key']}-installer"},
            "source": {
                "sourceType": "Catalog",
                "catalog": {
                    "packageName": op["package"],
                    "channels": [CHANNEL],
                    "version": op["head"],
                    "upgradeConstraintPolicy": "CatalogProvided",
                    "selector": {"matchLabels": {"olm.operatorframework.io/metadata.name": CATALOG_NAME}},
                },
            },
        },
    }


def render_clusterextension(op: dict[str, Any]) -> str:
    header = "\n".join([
        "# Generated by test/olmv1/gen-installer-rbac.py",
        "# Fields per OpenShift 4.22 docs olmv1-installing-an-operator.adoc and olmv1-clusterextension-api.adoc:",
        "#   spec.namespace, spec.serviceAccount.name, spec.source.sourceType=Catalog,",
        "#   spec.source.catalog.{packageName,channels,version,upgradeConstraintPolicy}.",
        f"# version is pinned to the exact catalog head ({op['head']}); no range, so nothing auto-updates during the experiment.",
        "# upgradeConstraintPolicy: CatalogProvided is the documented default, written out explicitly.",
        "# spec.source.catalog.selector: NOT in the two local doc snippets above (they only show channels/version),",
        "#   but it is part of the olm.operatorframework.io/v1 ClusterExtension API (CatalogFilter.selector, a",
        "#   LabelSelector over ClusterCatalog labels; catalogd labels every ClusterCatalog with",
        "#   olm.operatorframework.io/metadata.name=<catalog name>) and is documented in the OCP 'Catalog content",
        "#   resolution' page. It pins resolution to the openshift-redhat-operators ClusterCatalog so a same-named",
        "#   package in another catalog cannot win. If a 4.22 cluster rejected the field, drop the selector block.",
        "# No spec.config: all six operators are AllNamespaces-only; no watchNamespace is configured.",
    ])
    body = dump(clusterextension_object(op))
    # Quote the version so YAML never reads e.g. 5.7 as a float.
    body = body.replace(f"version: {op['head']}\n", f"version: \"{op['head']}\"\n")
    return header + "\n" + body


def render_kustomization(op: dict[str, Any]) -> str:
    return "# Generated by test/olmv1/gen-installer-rbac.py\n" + dump({
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": ["00-serviceaccount.yaml", "10-clusterrole.yaml", "20-clusterrolebinding.yaml", "30-clusterextension.yaml"],
    })


# --------------------------------------------------------------------------- driver
def generate(op: dict[str, Any]) -> dict[str, Any]:
    """Build everything for one operator; returns manifests (as strings) plus a summary."""
    csv = load_yaml_or_json(op["csv"])
    info = parse_csv(csv)
    others = load_bundle_objects(op.get("bundle"))
    groups = build_groups(op, info, others)
    manifests = {
        "00-serviceaccount.yaml": render_serviceaccount(op),
        "10-clusterrole.yaml": render_clusterrole(op, info, groups, op["csv"], op.get("bundle")),
        "20-clusterrolebinding.yaml": render_clusterrolebinding(op),
        "30-clusterextension.yaml": render_clusterextension(op),
        "kustomization.yaml": render_kustomization(op),
    }
    n_rules = sum(len(g.rules) for g in groups)
    unscoped = [(g.title, g.unscoped_reason) for g in groups if g.unscoped_reason]
    return {"op": op, "info": info, "others": others, "groups": groups, "manifests": manifests,
            "rules": n_rules, "unscoped": unscoped}


def write_outputs(result: dict[str, Any], out_dir: str) -> list[str]:
    key = result["op"]["key"]
    d = os.path.join(out_dir, key)
    os.makedirs(d, exist_ok=True)
    written = []
    for fn, text in result["manifests"].items():
        p = os.path.join(d, fn)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append(p)
    return written


def print_summary(results: list[dict[str, Any]]) -> None:
    print(f"{'key':<4} {'package':<30} {'head':<7} {'rules':>5} {'groups':>6} {'unscoped':>8}  bundle objects")
    for r in results:
        kinds: dict[str, int] = {}
        for o in r["others"]:
            kinds[o["kind"]] = kinds.get(o["kind"], 0) + 1
        kinds_s = ", ".join(f"{k}x{v}" for k, v in sorted(kinds.items())) or "-"
        print(f"{r['op']['key']:<4} {r['op']['package']:<30} {r['op']['head']:<7} {r['rules']:>5} {len(r['groups']):>6} {len(r['unscoped']):>8}  {kinds_s}")
    print()
    for r in results:
        print(f"[{r['op']['key']}] unscoped rule groups:")
        for title, reason in r["unscoped"]:
            print(f"  - {title}\n      why: {reason}")
    print()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT, help=f"output directory (default {DEFAULT_OUT})")
    ap.add_argument("--only", action="append", help="restrict to operator key(s)")
    args = ap.parse_args(argv)

    results = []
    for op in OPERATORS:
        if args.only and op["key"] not in args.only:
            continue
        r = generate(op)
        write_outputs(r, args.out)
        results.append(r)
    print_summary(results)
    print(f"wrote {sum(len(r['manifests']) for r in results)} files under {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
