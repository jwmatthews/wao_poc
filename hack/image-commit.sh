#!/usr/bin/env bash
# Print the git commit embedded in a medik8s operator image. Every medik8s operator is built by
# hack/build.sh, which passes version.GitCommit=$(git rev-parse HEAD) through -ldflags; the binary
# keeps that string, and `go version -m` prints it without running anything. OCI labels such as
# vcs-ref are inherited from the UBI base image and are NOT used.
# Exit codes: 0 commit printed; 2 image pulled but no version.GitCommit in any binary;
# 1 any other failure (missing tool, pull or network error).
# Usage: hack/image-commit.sh quay.io/medik8s/node-healthcheck-operator:v0.12.0
set -euo pipefail
ref=${1:?usage: $0 IMAGE}
command -v skopeo >/dev/null || { echo "skopeo is required" >&2; exit 1; }
command -v go >/dev/null || { echo "go is required" >&2; exit 1; }
tmp=$(mktemp -d); trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
skopeo copy --quiet --override-os linux --override-arch amd64 "docker://$ref" "dir:$tmp/img" >/dev/null
mkdir -p "$tmp/root"
for layer in $(jq -r '.layers[].digest' "$tmp/img/manifest.json" | sed 's/^sha256://'); do
  tar -xf "$tmp/img/$layer" -C "$tmp/root" 2>/dev/null || true
done
config=$(jq -r '.config.digest' "$tmp/img/manifest.json" | sed 's/^sha256://')
entry=$(jq -r '(.config.Entrypoint // .config.Cmd // [])[0] // empty' "$tmp/img/$config")
candidates=()
[ -n "$entry" ] && [ -f "$tmp/root/$entry" ] && candidates+=("$tmp/root/$entry")
while IFS= read -r f; do candidates+=("$f"); done < <(find "$tmp/root" -type f -perm -u+x -size +1M 2>/dev/null | head -50)
for bin in "${candidates[@]}"; do
  commit=$(go version -m "$bin" 2>/dev/null | sed -n 's/.*version\.GitCommit=\([0-9a-f]\{40\}\).*/\1/p' | head -1) || true
  if [ -n "$commit" ]; then echo "$commit"; exit 0; fi
done
echo "no version.GitCommit found in $ref" >&2
exit 2
