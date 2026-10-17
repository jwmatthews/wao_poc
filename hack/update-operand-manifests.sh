#!/usr/bin/env bash
# Copy each operand's upstream config/ tree at the commit recorded in release-set.yaml into
# config/operands/<k>/upstream/, following OADP's update-non-admin-manifests. Checkouts live in
# $OPERAND_SRC_DIR/<k> (default .cache/operands/<k>, git-ignored) unless <K>_PATH names one.
# A user-supplied checkout is never modified: objects are read with `git archive <commit>`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
RS=${RELEASE_SET:-release-set.yaml}
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
SRC_DIR=${OPERAND_SRC_DIR:-.cache/operands}
# Directories config/default never needs; everything else is kept so kustomize bases resolve.
PRUNE="samples scorecard manifests manifests-k8s manifests-ocp assets"

for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  K=$(tr '[:lower:]' '[:upper:]' <<<"$k"); path_var="${K}_PATH"
  repo=$("$YQ" ".components.$k.repo" "$RS")
  version=$("$YQ" ".components.$k.version" "$RS")
  tag=$("$YQ" ".components.$k.tag" "$RS")
  commit=$("$YQ" ".components.$k.commit" "$RS")
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "$k: release-set.yaml has no commit; run make update-release-set" >&2; exit 1; }
  dir=${!path_var:-$SRC_DIR/$k}
  if [ ! -d "$dir/.git" ]; then
    echo "== $k: cloning $repo into $dir"; mkdir -p "$(dirname "$dir")"; git clone --quiet --no-checkout "$repo" "$dir"
  fi
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "== $k: fetching $dir"; git -C "$dir" fetch --quiet --tags origin || true
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || { echo "$k: commit $commit not in $dir" >&2; exit 1; }
  fi
  echo "== $k: copying config/ at $commit ($version) from $dir"
  tmp=$(mktemp -d)
  git -C "$dir" archive "$commit" config | tar -x -C "$tmp"
  for d in $PRUNE; do rm -rf "$tmp/config/$d"; done
  rm -rf "config/operands/$k/upstream"; mkdir -p "config/operands/$k/upstream"
  mv "$tmp/config" "config/operands/$k/upstream/config"; rm -rf "$tmp"
  cat > "config/operands/$k/UPSTREAM.yaml" <<EOF
# Written by hack/update-operand-manifests.sh. Do not edit; run make update-operand-manifests.
repo: $repo
version: $version
tag: $tag
commit: $commit
EOF
done
[ "${SKIP_RENDER:-}" = 1 ] || make operand-manifests
