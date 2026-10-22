#!/usr/bin/env bash
# Validate the complete release set offline, then print ENV<TAB>pullRef records.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
RS=${RELEASE_SET:-release-set.yaml}
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
"$YQ" -o=json '.' "$RS" | jq -er '
  if (.components | type) != "object" or (.components | length) == 0
    then error("release-set has no components") else . end
  | [.components | to_entries[] | .key as $component | .value as $c
      | if ($c.images | type) != "object" or ($c.images | length) == 0
          then error($component + ": no images") else $c.images end
      | to_entries[] | {component: $component, tag: $c.tag, env: .key, image: .value}]
  | map(. as $entry | ($entry.component + "/" + $entry.env + ": ") as $where
      | .image as $img
      | if (.env | test("^RELATED_IMAGE_[A-Z0-9_]+$")) | not
          then error($where + "invalid image environment-variable name")
        elif (.tag | type) != "string" or (.tag | length) == 0
          then error($where + "missing component tag")
        elif ($img | type) != "object" then error($where + "missing image entry")
        elif ($img | has("pinned")) then error($where + "legacy pinned field; use pullRef")
        elif ($img.tagged | type) != "string" or ($img.tagged | length) == 0
          then error($where + "missing tagged reference")
        elif ($img.pullRef | type) != "string" or ($img.pullRef | length) == 0
          then error($where + "missing pullRef")
        else . end
      | ($img.tagged | sub(":[^:]*$"; "")) as $repo
      | if ($img.tagged != ($repo + ":" + .tag)) or ($repo | test("^[A-Za-z0-9]+([._-]+[A-Za-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)*$") | not)
          or (($repo | contains(":")) and ($repo | contains("/") | not))
          then error($where + "tagged reference must match component tag")
        elif .tag == "latest" then
          if $img.pullRef != $img.tagged then error($where + "latest pullRef must equal tagged") else . end
        elif ($img.pullRef | startswith($repo + "@")) | not
          then error($where + "pullRef must use the tagged image repository")
        elif ($img.pullRef | ltrimstr($repo + "@") | test("^sha256:[0-9a-f]{64}$")) | not
          then error($where + "non-latest pullRef must be a SHA-256 digest")
        else . end)
  | . as $entries
  | (group_by(.env) | map(select(length > 1)) | first) as $duplicate
  | if $duplicate != null then error($duplicate[0].component + "/" + $duplicate[0].env + ": duplicate image environment-variable name")
    else $entries | sort_by(.env)[] | [.env, .image.pullRef] | @tsv end'
