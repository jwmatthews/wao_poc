#!/usr/bin/env python3
# test/cluster/parity.py
"""Compare live operand Deployments and RBAC with the upstream bundle CSV.

Usage: parity.py --component nhc|snr|sbr|far|mdr|nmo [--namespace openshift-workload-availability]
Requires KUBECONFIG (passed explicitly to the CLI named by $OC, default kubectl). Reads the CSV
from .cache/bundles/<component>/manifests and maps upstream image tags to pinned digests from
release-set.yaml before comparing.
RBAC checked: each clusterPermissions ClusterRole, and for each namespaced `permissions` entry the
Role plus the ClusterRole and ClusterRoleBinding `<sa>-all-namespaces` that OLM would also create for an
AllNamespaces OperatorGroup.
Tolerated differences: the WAO-added webhook-server-cert volume and mount (D1), the WAO component
pod label (D10), and fields the bundle leaves unset that the API server defaults.
Exit 0 when identical, 1 with a unified diff otherwise.
"""
import argparse, difflib, json, os, pathlib, subprocess, sys

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]
WAO_VOLUME = "webhook-server-cert"
CONTAINER_FIELDS = ["image", "command", "args", "env", "ports", "livenessProbe", "readinessProbe", "startupProbe",
                    "securityContext", "resources", "volumeMounts"]


def image_map(release_set, component):
    return {i["upstream"]: i["pinned"] for i in release_set["components"][component]["images"].values()}


def bundle_csv(component):
    for f in sorted((REPO / ".cache/bundles" / component / "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            return obj
    raise SystemExit(f"no CSV for {component}; run `make bundles`")


def pin(obj, images):
    text = json.dumps(obj, sort_keys=True)
    for upstream, pinned in images.items():
        text = text.replace(json.dumps(upstream)[1:-1], json.dumps(pinned)[1:-1])
    return json.loads(text)


def normalize_deployment(spec):
    pod = spec["template"]["spec"]
    containers = []
    for c in pod["containers"]:
        cc = {f: c.get(f) for f in CONTAINER_FIELDS}
        cc["volumeMounts"] = [m for m in c.get("volumeMounts") or [] if m["name"] != WAO_VOLUME] or None
        containers.append(cc)
    return {"replicas": spec.get("replicas", 1), "selector": spec["selector"],
            "serviceAccountName": pod.get("serviceAccountName"), "tolerations": pod.get("tolerations"),
            "priorityClassName": pod.get("priorityClassName"), "securityContext": pod.get("securityContext"),
            "affinity": pod.get("affinity"), "topologySpreadConstraints": pod.get("topologySpreadConstraints"),
            "volumes": [v for v in pod.get("volumes") or [] if v["name"] != WAO_VOLUME] or None,
            "containers": containers}


def project(got, want):
    """Keep only the parts of got that want specifies, so API-server defaults
    (probe timeouts, port protocols, fieldRef apiVersion, ...) are not reported."""
    if isinstance(want, dict) and isinstance(got, dict):
        return {k: project(got.get(k), v) for k, v in want.items()}
    if isinstance(want, list) and isinstance(got, list) and len(want) == len(got):
        return [project(g, w) for g, w in zip(got, want)]
    return got


def diff(label, want, got):
    got = project(got, want)
    a = json.dumps(want, indent=1, sort_keys=True).splitlines()
    b = json.dumps(got, indent=1, sort_keys=True).splitlines()
    if a == b:
        print(f"OK {label}")
        return 0
    print(f"DIFF {label}")
    print("\n".join(difflib.unified_diff(a, b, "bundle", "live", lineterm="")))
    return 1


def compare_deployment(bundle_dep, live_spec, images):
    return diff(f"Deployment/{bundle_dep['name']}", normalize_deployment(pin(bundle_dep["spec"], images)), normalize_deployment(live_spec))


ALL_NAMESPACES_SUFFIX = "-all-namespaces"


def all_namespaces_name(sa):
    """Name of the cluster-wide copy of a CSV's namespaced permissions (OLM AllNamespaces behaviour)."""
    return sa + ALL_NAMESPACES_SUFFIX


def compare_rules(name, bundle_rules, live_rules, kind="ClusterRole"):
    key = lambda r: json.dumps(r, sort_keys=True)
    return diff(f"{kind}/{name}", sorted(bundle_rules, key=key), sorted(live_rules or [], key=key))


def compare_binding(name, role_name, sa, namespace, live, kind="ClusterRoleBinding", role_kind="ClusterRole"):
    want = {"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": role_kind, "name": role_name},
            "subjects": [{"kind": "ServiceAccount", "name": sa, "namespace": namespace}]}
    return diff(f"{kind}/{name}", want, {"roleRef": live.get("roleRef"), "subjects": live.get("subjects")})


def kubectl_json(*args):
    kc = os.environ.get("KUBECONFIG")
    if not kc:
        raise SystemExit("KUBECONFIG must be set")
    tool = os.environ.get("OC", "kubectl")
    return json.loads(subprocess.check_output([tool, "--kubeconfig", kc, *args, "-o", "json"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--component", required=True, choices=["nhc", "snr", "sbr", "far", "mdr", "nmo"])
    ap.add_argument("--namespace", default="openshift-workload-availability")
    a = ap.parse_args()
    release_set = yaml.safe_load((REPO / "release-set.yaml").read_text())
    images = image_map(release_set, a.component)
    spec = bundle_csv(a.component)["spec"]["install"]["spec"]
    failures = 0
    for d in spec["deployments"]:
        live = kubectl_json("get", "deployment", d["name"], "-n", a.namespace)
        failures += compare_deployment(d, live["spec"], images)
    for p in spec.get("clusterPermissions") or []:
        live = kubectl_json("get", "clusterrole", p["serviceAccountName"])
        failures += compare_rules(p["serviceAccountName"], p["rules"], live.get("rules"))
    for p in spec.get("permissions") or []:
        sa, name = p["serviceAccountName"], all_namespaces_name(p["serviceAccountName"])
        live = kubectl_json("get", "role", sa, "-n", a.namespace)
        failures += compare_rules(sa, p["rules"], live.get("rules"), kind="Role")
        live = kubectl_json("get", "clusterrole", name)
        failures += compare_rules(name, p["rules"], live.get("rules"))
        live = kubectl_json("get", "clusterrolebinding", name)
        failures += compare_binding(name, name, sa, a.namespace, live)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
