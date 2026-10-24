#!/usr/bin/env bash
# Copy each operand's config/ tree at the commit recorded in release-set.yaml into
# config/operands/<k>/config/, following OADP's update-non-admin-manifests. Checkouts live in
# $OPERAND_SRC_DIR/<k> (default .cache/operands/<k>, git-ignored) unless <K>_PATH names one.
# A user-supplied checkout is never modified: objects are read with `git archive <commit>`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
RS=${RELEASE_SET:-release-set.yaml}
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
SRC_DIR=${OPERAND_SRC_DIR:-.cache/operands}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  K=$(tr '[:lower:]' '[:upper:]' <<<"$k"); path_var="${K}_PATH"
  repo=$("$YQ" ".components.$k.repo" "$RS")
  tag=$("$YQ" ".components.$k.tag" "$RS")
  commit=$("$YQ" ".components.$k.commit" "$RS")
  overlay=$("$YQ" ".components.$k.overlay" "$RS")
  [[ "$overlay" =~ ^config/[A-Za-z0-9_/.-]+$ ]] || { echo "$k: release-set.yaml has no overlay (the copied kustomize directory WAO renders, e.g. config/default)" >&2; exit 1; }
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "$k: release-set.yaml has no commit; run make update-release-set" >&2; exit 1; }
  dir=${!path_var:-$SRC_DIR/$k}
  if [ ! -d "$dir/.git" ]; then
    echo "== $k: cloning $repo into $dir"; mkdir -p "$(dirname "$dir")"; git clone --quiet --no-checkout "$repo" "$dir"
  fi
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "== $k: fetching $dir"; git -C "$dir" fetch --quiet --tags origin || true
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || { echo "$k: commit $commit not in $dir" >&2; exit 1; }
  fi
  echo "== $k: copying config/ at $commit (tag: $tag) from $dir"
  tmp=$work/$k; rm -rf "$tmp"; mkdir -p "$tmp"
  git -C "$dir" archive "$commit" config | tar -x -C "$tmp"
  mkdir -p "config/operands/$k"
  rm -rf "config/operands/$k/config"
  mv "$tmp/config" "config/operands/$k/config"
  cat > "config/operands/$k/VENDORED.yaml" <<EOF
# Written by hack/update-operand-manifests.sh. Do not edit; run make update-operand-manifests.
repo: $repo
tag: $tag
commit: $commit
overlay: $overlay
EOF
done
[ "${SKIP_RENDER:-}" = 1 ] || make operand-manifests
