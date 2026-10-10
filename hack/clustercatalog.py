#!/usr/bin/env python3
# hack/clustercatalog.py
"""Print the OLM v1 ClusterCatalog manifest for a catalog image (digest reference only)."""
import argparse, re, sys
import yaml

DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", required=True)
    ap.add_argument("--image", required=True, help="catalog image, digest reference")
    a = ap.parse_args()
    if not DIGEST_RE.search(a.image):
        print(f"clustercatalog: --image must be a digest reference (…@sha256:<64 hex>), got {a.image!r}", file=sys.stderr)
        sys.exit(2)
    obj = {"apiVersion": "olm.operatorframework.io/v1", "kind": "ClusterCatalog",
           "metadata": {"name": a.name},
           "spec": {"availabilityMode": "Available", "priority": 0,
                    "source": {"type": "Image", "image": {"ref": a.image}}}}
    print(yaml.safe_dump(obj, sort_keys=False, width=4096), end="")


if __name__ == "__main__":
    main()
