#!/usr/bin/env bash
# Rewrite release-set.yaml from published operand images.
# For each component: pick a tag, resolve each image's digest, read the embedded git commit from
# the operator binary (hack/image-commit.sh), and write version, commit, upstream and pinned.
#
# Tag selection (first match wins): <K>_TAG (e.g. NHC_TAG=v0.12.0), OPERAND_TAG, or the latest
# GitHub release. Special values: OPERAND_TAG=pinned keeps the version already in the file;
# OPERAND_TAG=latest selects the post-submit main build.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
RS=${RELEASE_SET:-release-set.yaml}
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
for tool in curl skopeo jq go "$YQ"; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }; done

latest_release() { # repo-url -> tag_name
  local api; api=$(sed 's#https://github.com/#https://api.github.com/repos/#' <<<"$1")/releases/latest
  curl -fsSL -H 'Accept: application/vnd.github+json' "$api" | jq -r .tag_name
}
digest_ref() { # tag-ref -> repo@sha256:...
  local repo=${1%:*} d; d=$(skopeo inspect --raw --override-os linux --override-arch amd64 "docker://$1" | shasum -a 256 | cut -d' ' -f1)
  echo "$repo@sha256:$d"
}

for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  K=$(tr '[:lower:]' '[:upper:]' <<<"$k"); override_var="${K}_TAG"
  repo=$("$YQ" ".components.$k.repo" "$RS")
  current=$("$YQ" ".components.$k.tag" "$RS")
  tag=${!override_var:-${OPERAND_TAG:-release}}
  case "$tag" in
    release) tag=$(latest_release "$repo") ;;
    pinned)  tag=$current ;;
  esac
  echo "== $k: $repo @ $tag"
  commit=""
  for env in $("$YQ" ".components.$k.images | keys | .[]" "$RS"); do
    base=$("$YQ" ".components.$k.images.$env.upstream" "$RS"); base=${base%:*}
    upstream="$base:$tag"
    pinned=$(digest_ref "$upstream")
    c=$(hack/image-commit.sh "$upstream" 2>/dev/null || true)
    if [ -z "$c" ]; then echo "   $env: no embedded commit (skipping commit check for this image)"; fi
    if [ -n "$c" ] && [ -n "$commit" ] && [ "$c" != "$commit" ]; then
      echo "   $env: embedded commit $c differs from $commit" >&2; exit 1
    fi
    [ -n "$c" ] && commit=$c
    echo "   $env: $pinned"
    "$YQ" -i ".components.$k.images.$env.upstream = \"$upstream\" | .components.$k.images.$env.pinned = \"$pinned\"" "$RS"
  done
  [ -n "$commit" ] || { echo "   no image of $k embeds version.GitCommit" >&2; exit 1; }
  echo "   commit: $commit"
  # A release tag is also the version label; a `latest` build keeps the label already in the file.
  "$YQ" -i ".components.$k.tag = \"$tag\" | .components.$k.commit = \"$commit\"" "$RS"
  [[ "$tag" =~ ^v[0-9] ]] && "$YQ" -i ".components.$k.version = \"$tag\"" "$RS"
done
"$YQ" -i ".resolvedAt = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$RS"
echo "updated $RS; next: make update-operand-manifests"
