#!/usr/bin/env python3
# hack/bundle-annotations.py
"""Add the OpenShift bundle annotation and label that `operator-sdk generate bundle` does not emit.

com.redhat.openshift.versions declares the OpenShift releases the bundle targets (Red Hat
certification policy syntax: "v4.18" is open-ended from 4.18). Written to
bundle/metadata/annotations.yaml and as a LABEL in bundle.Dockerfile, before the COPY lines.
Idempotent: safe to run after every `make bundle`.
"""
import argparse, pathlib
import yaml

KEY = "com.redhat.openshift.versions"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bundle", default="bundle")
    ap.add_argument("--dockerfile", default="bundle.Dockerfile")
    ap.add_argument("--openshift-versions", required=True, help='e.g. "v4.18" or "v4.18-v4.22"')
    a = ap.parse_args()

    ann_path = pathlib.Path(a.bundle, "metadata", "annotations.yaml")
    doc = yaml.safe_load(ann_path.read_text())
    doc["annotations"][KEY] = a.openshift_versions
    ann_path.write_text(yaml.safe_dump(doc, sort_keys=False, width=4096))

    df = pathlib.Path(a.dockerfile)
    lines = [l for l in df.read_text().splitlines() if not l.startswith(f"LABEL {KEY}=")]
    label = f'LABEL {KEY}="{a.openshift_versions}"'
    first_copy = next((i for i, l in enumerate(lines) if l.startswith("COPY ")), len(lines))
    lines.insert(first_copy, label)
    df.write_text("\n".join(lines) + "\n")
    print(f"{KEY}={a.openshift_versions} written to {ann_path} and {df}")


if __name__ == "__main__":
    main()
