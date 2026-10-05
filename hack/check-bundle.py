#!/usr/bin/env python3
# hack/check-bundle.py
"""Assert the generated bundle matches the POC contract and release-set.yaml. Exit 1 with reasons."""
import pathlib, sys

import yaml

EXPECTED_CRDS = {
    "workloadavailabilityconfigs.workloadavailability.medik8s.io",
    "nodehealthchecks.remediation.medik8s.io",
    "selfnoderemediationconfigs.self-node-remediation.medik8s.io",
    "selfnoderemediations.self-node-remediation.medik8s.io",
    "selfnoderemediationtemplates.self-node-remediation.medik8s.io",
    "storagebasedremediationconfigs.storage-based-remediation.medik8s.io",
    "storagebasedremediations.storage-based-remediation.medik8s.io",
    "storagebasedremediationtemplates.storage-based-remediation.medik8s.io",
    "fenceagentsremediations.fence-agents-remediation.medik8s.io",
    "fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io",
    "machinedeletionremediations.machine-deletion-remediation.medik8s.io",
    "machinedeletionremediationtemplates.machine-deletion-remediation.medik8s.io",
    "nodemaintenances.nodemaintenance.medik8s.io",
}


def pinned_images(release_set_path):
    rs = yaml.safe_load(pathlib.Path(release_set_path).read_text())
    return {env: img["pinned"] for comp in rs["components"].values() for env, img in comp["images"].items()}


def main(bundle_dir="bundle", release_set="release-set.yaml"):
    pinned = pinned_images(release_set)
    problems, csv, crds, extra = [], None, set(), []
    for f in sorted(pathlib.Path(bundle_dir, "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            csv = obj
        elif obj["kind"] == "CustomResourceDefinition":
            crds.add(obj["metadata"]["name"])
        else:
            extra.append(f"{obj['kind']}/{obj['metadata']['name']}")
    if csv is None:
        sys.exit("no CSV in bundle")
    spec = csv["spec"]
    owned = {c["name"] for c in spec["customresourcedefinitions"].get("owned", [])}
    if owned != EXPECTED_CRDS:
        problems.append(f"owned CRDs differ: missing={sorted(EXPECTED_CRDS - owned)} unexpected={sorted(owned - EXPECTED_CRDS)}")
    if crds != EXPECTED_CRDS:
        problems.append(f"bundle CRD files differ: missing={sorted(EXPECTED_CRDS - crds)} unexpected={sorted(crds - EXPECTED_CRDS)}")
    related = {ri["image"] for ri in spec.get("relatedImages", []) or []}
    if not set(pinned.values()) <= related:
        problems.append(f"relatedImages missing pinned images: {sorted(set(pinned.values()) - related)}")
    modes = {m["type"]: m["supported"] for m in spec["installModes"]}
    if modes != {"OwnNamespace": False, "SingleNamespace": False, "MultiNamespace": False, "AllNamespaces": True}:
        problems.append(f"installModes = {modes}")
    deployments = spec["install"]["spec"]["deployments"]
    if len(deployments) != 1:
        problems.append(f"CSV must deploy only the WAO controller, got {[d['name'] for d in deployments]}")
    else:
        container = deployments[0]["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e.get("value") for e in container.get("env", [])}
        for name, image in pinned.items():
            if env.get(name) != image:
                problems.append(f"WAO Deployment env {name}={env.get(name)!r}, release-set.yaml pins {image!r}")
        if "OPERATOR_NAMESPACE" not in env:
            problems.append("WAO Deployment lacks OPERATOR_NAMESPACE")
    if csv["metadata"]["annotations"].get("operatorframework.io/suggested-namespace") != "openshift-workload-availability":
        problems.append("suggested-namespace annotation missing or wrong")
    if extra:
        problems.append(f"bundle contains objects a ConfigMap catalog cannot carry: {extra}")
    if problems:
        print("\n".join(problems)); sys.exit(1)
    print(f"bundle OK: {csv['metadata']['name']} owns {len(owned)} CRDs, {len(pinned)} pinned operand images")


if __name__ == "__main__":
    main(*sys.argv[1:])
