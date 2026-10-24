#!/usr/bin/env bash
# Validate operands.yaml and selected image destinations offline, then emit ENV<TAB>repository:tag.
# Source fields are checked for shape only; rendering never needs operand checkouts.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
keys=("$@"); [ ${#keys[@]} -gt 0 ] || keys=(nhc snr sbr far mdr nmo)
seen=" "
for key in "${keys[@]}"; do
  case "$key" in nhc|snr|sbr|far|mdr|nmo) ;; *) echo "unknown operand: $key" >&2; exit 1 ;; esac
  case "$seen" in *" $key "*) echo "duplicate operand: $key" >&2; exit 1 ;; esac
  seen+="$key "
done
work=$(mktemp); trap 'rm -f "$work"' EXIT

# Keep the six operand/eight image contract in one validator, shared by every caller.
"$YQ" -o=json '.' operands.yaml | jq -er --args '
  def nonempty: type == "string" and test("\\S") and (test("[\\t\\r\\n]") | not);
  {nhc: ["RELATED_IMAGE_NHC_CONSOLE", "RELATED_IMAGE_NHC_MANAGER"],
   snr: ["RELATED_IMAGE_SNR_MANAGER"], sbr: ["RELATED_IMAGE_SBR_AGENT", "RELATED_IMAGE_SBR_MANAGER"],
   far: ["RELATED_IMAGE_FAR_MANAGER"], mdr: ["RELATED_IMAGE_MDR_MANAGER"],
   nmo: ["RELATED_IMAGE_NMO_MANAGER"]} as $required
  | if (.operands | type) != "object" or (.operands | keys) != ($required | keys)
      then error("operands.yaml must contain exactly nhc, snr, sbr, far, mdr, nmo") else . end
  | [.operands | to_entries[] | .key as $key | .value
      | if (.source.path | nonempty) and (.source.branch | nonempty) then .
        else error($key + ": source.path and source.branch must be nonempty strings") end
      | if (.images | type) == "object" and (.images | length) > 0 then .
        else error($key + ": no images") end
      | .images | to_entries[] | {key: $key, env: .key, image: .value}]
  | . as $entries
  | (group_by(.env) | map(select(length > 1)) | first) as $duplicate
  | if $duplicate != null then error($duplicate[0].key + "/" + $duplicate[0].env + ": image environment-variable names must be unique") else . end
  | map(. as $entry | ($entry.key + "/" + $entry.env + ": ") as $where
      | if ([ $entries[] | select(.key == $entry.key) | .env ] | sort) != $required[$entry.key]
          then error($where + "images must contain exactly " + ($required[$entry.key] | join(", ")))
        elif (.image.repository | type) != "string" then error($where + "missing repository")
        elif (.image.repository | test("^[A-Za-z0-9]+([._-]+[A-Za-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)*$") | not)
          or ((.image.repository | contains(":")) and (.image.repository | contains("/") | not))
          then error($where + "repository must be an image path without a tag or digest")
        elif (.image.tag | type) != "string" then error($where + "missing nonempty tag")
        elif (.image.tag | test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$") | not)
          then error($where + "invalid image tag")
        elif .env == "RELATED_IMAGE_SBR_AGENT" then
          if (.image | has("kustomizeName")) then error($where + "agent uses an environment value; omit kustomizeName") else . end
        elif (.image.kustomizeName | nonempty | not) then error($where + "missing kustomizeName")
        else . end)
  | sort_by(.env)[] | select(.key as $key | $ARGS.positional | index($key))
  | [.key, .env, .image.repository, .image.tag, (.image.kustomizeName // "")] | @tsv
' "${keys[@]}" > "$work"

require_one() {
  local file=$1 query=$2 count
  count=$("$YQ" -o=json '.' "$file" | jq -s "$query | length")
  [ "$count" = 1 ] || { echo "$key/$env: expected exactly one image destination in $file" >&2; exit 1; }
}

# Preflight every selected destination before emitting records or allowing any mutation.
while IFS=$'\t' read -r key env repository tag name; do
  export WAO_IMAGE_ENV="$env" WAO_IMAGE_NAME="$name"
  require_one config/manager/manager.yaml \
    '[.[] | select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == env.WAO_IMAGE_ENV)]'
  runtime=config/operands/$key/overlays/runtime
  if [ -n "$name" ]; then
    require_one "$runtime/kustomization.yaml" '[.[] | .images[] | select(.name == env.WAO_IMAGE_NAME)]'
  fi
  case "$env" in
    RELATED_IMAGE_SNR_MANAGER) patch=manager_image_env_patch.yaml; export WAO_IMAGE_ENV=SELF_NODE_REMEDIATION_IMAGE ;;
    RELATED_IMAGE_SBR_AGENT) patch=agent_image_env_patch.yaml; export WAO_IMAGE_ENV=RELATED_IMAGE_AGENT ;;
    *) continue ;;
  esac
  require_one "$runtime/$patch" \
    '[.[] | .spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == env.WAO_IMAGE_ENV)]'
done < "$work"
while IFS=$'\t' read -r key env repository tag name; do
  printf '%s\t%s:%s\n' "$env" "$repository" "$tag"
done < "$work"
