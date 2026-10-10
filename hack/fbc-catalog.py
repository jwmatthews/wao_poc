#!/usr/bin/env python3
# hack/fbc-catalog.py
"""Render a File-Based Catalog (FBC) for OLM v1 from a registry+v1 bundle directory (D6).

Writes <out>/<package>/catalog.json with one JSON object per line: olm.package, olm.channel,
olm.bundle. The bundle image must be a digest reference: operator-controller unpacks the bundle
image itself and caches it by reference, so a tag would make the catalog mutable.
"""
import argparse, json, pathlib, re, sys
import yaml

DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")
CSV_METADATA_FIELDS = ("annotations", "description", "displayName", "installModes", "keywords", "labels",
                       "links", "maintainers", "maturity", "minKubeVersion", "provider")


def fail(msg):
    print(f"fbc-catalog: {msg}", file=sys.stderr)
    sys.exit(2)


def load_bundle(bundle_dir):
    bundle = pathlib.Path(bundle_dir)
    ann = yaml.safe_load((bundle / "metadata" / "annotations.yaml").read_text())["annotations"]
    csvs, crds = [], []
    for f in sorted((bundle / "manifests").glob("*.yaml")):
        obj = yaml.safe_load(f.read_text())
        if obj["kind"] == "ClusterServiceVersion":
            csvs.append(obj)
        elif obj["kind"] == "CustomResourceDefinition":
            crds.append(obj)
    if len(csvs) != 1:
        fail(f"bundle must contain exactly one CSV, found {len(csvs)}")
    return ann, csvs[0], crds


def csv_metadata(csv):
    spec, meta = csv["spec"], csv["metadata"]
    value = {"annotations": meta.get("annotations", {})}
    for field in CSV_METADATA_FIELDS[1:]:
        if field in spec:
            value[field] = spec[field]
    owned = spec.get("customresourcedefinitions", {}).get("owned", [])
    value["crdDescriptions"] = {"owned": [{k: c[k] for k in ("name", "version", "kind", "displayName", "description") if k in c}
                                          for c in owned]}
    return value


def gvks(crds):
    out = []
    for crd in crds:
        for v in crd["spec"]["versions"]:
            if v.get("served", True):
                out.append({"group": crd["spec"]["group"], "kind": crd["spec"]["names"]["kind"], "version": v["name"]})
    return sorted(out, key=lambda g: (g["group"], g["kind"], g["version"]))


def related_images(csv, bundle_image):
    images = {ri["image"]: ri["name"] for ri in csv["spec"].get("relatedImages", []) or []}
    for d in csv["spec"]["install"]["spec"]["deployments"]:
        for c in d["spec"]["template"]["spec"]["containers"]:
            images.setdefault(c["image"], "")
    images.setdefault(bundle_image, "")
    return [{"name": name, "image": image} for image, name in sorted(images.items())]


def render(bundle_dir, bundle_image):
    if not DIGEST_RE.search(bundle_image):
        fail(f"--bundle-image must be a digest reference (…@sha256:<64 hex>), got {bundle_image!r}")
    ann, csv, crds = load_bundle(bundle_dir)
    package = ann["operators.operatorframework.io.bundle.package.v1"]
    default_channel = ann["operators.operatorframework.io.bundle.channel.default.v1"]
    channels = ann["operators.operatorframework.io.bundle.channels.v1"].split(",")
    name, version = csv["metadata"]["name"], str(csv["spec"]["version"])
    properties = [{"type": "olm.package", "value": {"packageName": package, "version": version}}]
    properties += [{"type": "olm.gvk", "value": g} for g in gvks(crds)]
    properties.append({"type": "olm.csv.metadata", "value": csv_metadata(csv)})
    blobs = [{"schema": "olm.package", "name": package, "defaultChannel": default_channel}]
    blobs += [{"schema": "olm.channel", "name": ch, "package": package, "entries": [{"name": name}]} for ch in channels]
    blobs.append({"schema": "olm.bundle", "name": name, "package": package, "image": bundle_image,
                  "properties": properties, "relatedImages": related_images(csv, bundle_image)})
    return package, blobs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bundle", required=True, help="bundle directory (manifests/, metadata/)")
    ap.add_argument("--bundle-image", required=True, help="bundle image, digest reference")
    ap.add_argument("--out", required=True, help="FBC root directory, e.g. dist/catalog")
    a = ap.parse_args()
    package, blobs = render(a.bundle, a.bundle_image)
    out = pathlib.Path(a.out, package)
    out.mkdir(parents=True, exist_ok=True)
    (out / "catalog.json").write_text("".join(json.dumps(b, sort_keys=True) + "\n" for b in blobs))
    print(f"wrote {out / 'catalog.json'}: {len(blobs)} blobs, bundle {blobs[-1]['name']} -> {a.bundle_image}")


if __name__ == "__main__":
    main()
