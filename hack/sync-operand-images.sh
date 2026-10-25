#!/usr/bin/env bash
# Synchronize selected image settings from operands.yaml. No copying, rendering or registry calls.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
refs=$(YQ="$YQ" hack/operand-image-refs.sh "$@")

set_env() {
  local file=$1
  local query='(select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == strenv(WAO_IMAGE_ENV)) | .value)'
  [ "$("$YQ" "$query" "$file")" = "$WAO_IMAGE_REF" ] || "$YQ" -i "$query = strenv(WAO_IMAGE_REF)" "$file"
}

while IFS=$'\t' read -r env ref; do
  # The validated environment name identifies its operand and YAML image entry.
  key=$(cut -d_ -f3 <<< "$env" | tr '[:upper:]' '[:lower:]')
  export WAO_OPERAND_KEY="$key" WAO_IMAGE_ENV="$env" WAO_IMAGE_REF="$ref"
  set_env config/manager/manager.yaml
  runtime=config/operands/$key/overlays/runtime
  name=$("$YQ" '.operands[strenv(WAO_OPERAND_KEY)].images[strenv(WAO_IMAGE_ENV)].kustomizeName // ""' operands.yaml)
  if [ -n "$name" ]; then
    export WAO_IMAGE_NAME="$name" WAO_IMAGE_REPOSITORY="${ref%:*}" WAO_IMAGE_TAG="${ref##*:}"
    query='(.images[] | select(.name == strenv(WAO_IMAGE_NAME)))'
    current=$("$YQ" "$query | (.newName + \":\" + .newTag)" "$runtime/kustomization.yaml")
    digest=$("$YQ" "$query | .digest // \"\"" "$runtime/kustomization.yaml")
    if [ "$current" != "$ref" ] || [ -n "$digest" ]; then
      "$YQ" -i "$query |= (.newName = strenv(WAO_IMAGE_REPOSITORY) | .newTag = strenv(WAO_IMAGE_TAG) | del(.digest))" "$runtime/kustomization.yaml"
    fi
  fi
  case "$env" in
    RELATED_IMAGE_SNR_MANAGER) export WAO_IMAGE_ENV=SELF_NODE_REMEDIATION_IMAGE; set_env "$runtime/manager_image_env_patch.yaml" ;;
    RELATED_IMAGE_SBR_AGENT) export WAO_IMAGE_ENV=RELATED_IMAGE_AGENT; set_env "$runtime/agent_image_env_patch.yaml" ;;
  esac
done <<< "$refs"
