#!/usr/bin/env bash
set -euo pipefail

# controller-gen's Quantity pattern permits fractional and overflowing exponents.
# Match ParseQuantity's integer exponent range before a typed client can read the CR.
# Keep the standard ResourceRequirements Go type. Expose its supported keys so the
# console can create separate CPU and memory fields instead of a generic map.
decimal_range() {
  local bound="$1" index digit remaining alternatives
  alternatives="[0-9]{1,$((${#bound} - 1))}"
  for ((index = 0; index < ${#bound}; index++)); do
    digit="${bound:index:1}"
    remaining=$((${#bound} - index - 1))
    if ((digit > 0)); then
      alternatives+="|${bound:0:index}[0-$((digit - 1))][0-9]{$remaining}"
    fi
  done
  printf '0*(%s|%s)' "$alternatives" "$bound"
}

positive_exponent="$(decimal_range 9223372036854775807)"
negative_exponent="$(decimal_range 9223372036854775808)"
exponent="[eE]([+]?${positive_exponent}|-${negative_exponent})"
export WAO_QUANTITY_PATTERN="^([+]|-)?(([0-9]+([.][0-9]*)?)|([.][0-9]+))(([KMGTPE]i)|[numkMGTPE]|${exponent})?$"

: "${YQ:?YQ must name the pinned yq binary}"
crd="${1:?pass the generated WAO CRD path}"

# The console cannot render anyOf. The string type selects its text widget.
# x-kubernetes-int-or-string still permits integer quantities at API admission.
# The format also preserves both types in server-side apply's schema converter.
for WAO_RESOURCE_FIELD in requests limits; do
  export WAO_RESOURCE_FIELD
  "$YQ" -i '
    (.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.components.properties[]
      .properties.manager.properties.resources.properties[strenv(WAO_RESOURCE_FIELD)]) |= (
      .properties = {"cpu": (.properties.cpu // .additionalProperties), "memory": (.properties.memory // .additionalProperties)} |
      del(.additionalProperties) |
      .properties[] |= (
        .pattern = strenv(WAO_QUANTITY_PATTERN) |
        .type = "string" |
        .format = "int-or-string" |
        del(.anyOf)
      )
    )
  ' "$crd"
done
