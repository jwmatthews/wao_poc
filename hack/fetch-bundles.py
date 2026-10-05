#!/usr/bin/env python3
"""Fetch OLM registry+v1 bundle images by digest and unpack manifests/ and metadata/.

Usage: fetch-bundles.py --release-set release-set.yaml --out .cache/bundles

Uses the anonymous OCI distribution API (no container runtime needed). Every blob
is verified against its digest. Output layout: <out>/<component>/{manifests,metadata}/
plus <out>/<component>/fetch.json recording the image reference and file hashes.
"""
import argparse, gzip, hashlib, io, json, pathlib, shutil, sys, tarfile, urllib.request

import yaml

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def split_ref(ref):
    registry, rest = ref.split("/", 1)
    repo, digest = rest.split("@", 1)
    return registry, repo, digest


def token(registry, repo):
    url = f"https://{registry}/v2/auth?service={registry}&scope=repository:{repo}:pull"
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)["token"]


def get(registry, repo, path, tok, accept=None):
    req = urllib.request.Request(f"https://{registry}/v2/{repo}/{path}")
    req.add_header("Authorization", f"Bearer {tok}")
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def verified(data, digest):
    algo, want = digest.split(":", 1)
    if algo != "sha256" or hashlib.sha256(data).hexdigest() != want:
        raise SystemExit(f"digest mismatch for {digest}")
    return data


def fetch(ref, dest):
    registry, repo, digest = split_ref(ref)
    tok = token(registry, repo)
    manifest = json.loads(verified(get(registry, repo, f"manifests/{digest}", tok, ACCEPT), digest))
    if "manifests" in manifest:  # index: bundles are platform independent, take linux/amd64 or the first entry
        entries = manifest["manifests"]
        chosen = next((m for m in entries if m.get("platform", {}).get("architecture") == "amd64"), entries[0])
        manifest = json.loads(verified(get(registry, repo, f"manifests/{chosen['digest']}", tok, ACCEPT), chosen["digest"]))
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    for layer in manifest["layers"]:
        blob = verified(get(registry, repo, f"blobs/{layer['digest']}", tok), layer["digest"])
        raw = gzip.decompress(blob) if blob[:2] == b"\x1f\x8b" else blob
        with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
            for m in tar.getmembers():
                name = m.name.lstrip("./")
                if not m.isfile() or not (name.startswith("manifests/") or name.startswith("metadata/")):
                    continue
                target = dest / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(m).read())
    files = {str(p.relative_to(dest)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(dest.rglob("*")) if p.is_file()}
    if not any(f.startswith("manifests/") for f in files):
        raise SystemExit(f"{ref}: no manifests/ found")
    (dest / "fetch.json").write_text(json.dumps({"image": ref, "files": files}, indent=2, sort_keys=True) + "\n")
    return len(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release-set", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rs = yaml.safe_load(pathlib.Path(a.release_set).read_text())
    for name, comp in sorted(rs["components"].items()):
        n = fetch(comp["bundle"], pathlib.Path(a.out) / name)
        print(f"{name}: {comp['bundle']} -> {n} files")


if __name__ == "__main__":
    sys.exit(main())
