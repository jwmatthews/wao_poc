#!/usr/bin/env bash
# Copy selected local working-tree config/ directories, then synchronize their image settings.
# WAO overlays are kept intact. Rendering and bundle generation are separate Make targets.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
keys=("$@"); [ ${#keys[@]} -gt 0 ] || keys=(nhc snr sbr far mdr nmo)
# Validate keys, YAML, and all selected image destinations before touching copied configuration.
YQ="$YQ" hack/operand-image-refs.sh "${keys[@]}" >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "$key: $*" >&2; exit 1; }

# Validate and stage all selected sources before replacing the first destination.
for key in "${keys[@]}"; do
  export WAO_OPERAND_KEY="$key"
  source_path=$("$YQ" '.operands[strenv(WAO_OPERAND_KEY)].source.path' operands.yaml)
  expected=$("$YQ" '.operands[strenv(WAO_OPERAND_KEY)].source.branch' operands.yaml)
  source=$(cd "$source_path" 2>/dev/null && pwd -P) || fail "source.path does not exist: $source_path"
  git_root=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) || fail "$source is not a Git repository"
  [ "$source" = "$(cd "$git_root" && pwd -P)" ] || fail "source.path must name the Git repository root: $source"
  branch=$(git -C "$source" symbolic-ref --quiet --short HEAD) || fail "checkout must be on branch $expected (detached HEAD)"
  [ "$branch" = "$expected" ] || fail "expected branch $expected, found $branch in $source"
  config=$(cd "$source/config" 2>/dev/null && pwd -P) || fail "missing config/ in $source"
  destination=$(cd "config/operands/$key" && pwd -P)/config
  # Reject either direction of overlap, including a config/ symlink back into WAO.
  case "$destination/" in "$config/"*) fail "source config overlaps $destination" ;; esac
  case "$config/" in "$destination/"*) fail "source config overlaps $destination" ;; esac
  cp -R "$config" "$work/$key" || fail "failed to stage config/ from $source"
done
for key in "${keys[@]}"; do
  echo "== $key: copying config/ from the selected working tree"
  rm -rf "config/operands/$key/config"
  mv "$work/$key" "config/operands/$key/config" || fail "failed to replace copied config/; rerun the update"
done
YQ="$YQ" hack/sync-operand-images.sh "${keys[@]}"
