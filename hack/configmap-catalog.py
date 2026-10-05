#!/usr/bin/env python3
"""Render a ConfigMap-backed OLM CatalogSource from a registry+v1 bundle directory (POC only, D6)."""
import argparse, json, pathlib, sys
import yaml


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--package", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--namespace", default="openshift-marketplace")
    a = ap.parse_args()
    crds, csvs, extra = [], [], []
    for f in sorted(pathlib.Path(a.bundle, "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        {"CustomResourceDefinition": crds, "ClusterServiceVersion": csvs}.get(obj["kind"], extra).append(obj)
    if len(csvs) != 1:
        sys.exit(f"expected one CSV, found {len(csvs)}")
    if extra:
        sys.exit("ConfigMap catalogs carry only CRDs and CSVs; remove: " + ", ".join(f"{o['kind']}/{o['metadata']['name']}" for o in extra))
    data = {"customResourceDefinitions": json.dumps(crds, sort_keys=True),
            "clusterServiceVersions": json.dumps(csvs, sort_keys=True),
            "packages": json.dumps([{"packageName": a.package, "defaultChannel": a.channel,
                                     "channels": [{"name": a.channel, "currentCSV": csvs[0]["metadata"]["name"]}]}])}
    size = sum(len(v) for v in data.values())
    if size > 900 * 1024:
        sys.exit(f"catalog data {size} bytes exceeds the ConfigMap budget")
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": a.name, "namespace": a.namespace}, "data": data}
    cs = {"apiVersion": "operators.coreos.com/v1alpha1", "kind": "CatalogSource",
          "metadata": {"name": a.name, "namespace": a.namespace},
          "spec": {"sourceType": "internal", "configMap": a.name, "displayName": "WAO POC catalog", "publisher": "wao_poc"}}
    print("---\n".join(yaml.safe_dump(x, sort_keys=False, width=4096) for x in (cm, cs)), end="")


if __name__ == "__main__":
    main()
