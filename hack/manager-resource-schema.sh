#!/usr/bin/env bash
set -euo pipefail

# controller-gen's Quantity pattern permits fractional and overflowing exponents.
# Match ParseQuantity's integer exponent range before a typed client can read the CR.
# Keep the standard ResourceRequirements Go type and validate every resource map value.
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

"${YQ:?YQ must name the pinned yq binary}" -i '
  (.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.components.properties[]
    .properties.manager.properties.resources.properties.requests.additionalProperties.pattern) = strenv(WAO_QUANTITY_PATTERN) |
  (.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.components.properties[]
    .properties.manager.properties.resources.properties.limits.additionalProperties.pattern) = strenv(WAO_QUANTITY_PATTERN)
' "${1:?pass the generated WAO CRD path}"
