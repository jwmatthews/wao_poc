#!/usr/bin/env bash
set -euo pipefail

# The console details page flattens nested descriptors into their first object.
# Identify each component in every editable label and keep its controls together.
csv="${1:?pass the generated base CSV path}"
: "${YQ:?YQ must name the pinned yq binary}"

while IFS=$'\t' read -r WAO_COMPONENT_PATH WAO_COMPONENT_NAME; do
  export WAO_COMPONENT_PATH WAO_COMPONENT_NAME
  "$YQ" -i '
    (.spec.customresourcedefinitions.owned[] |
      select(.name == "workloadavailabilityconfigs.workloadavailability.medik8s.io") |
      .specDescriptors[] | select(.path == strenv(WAO_COMPONENT_PATH) + ".enabled") |
      .displayName) = strenv(WAO_COMPONENT_NAME) + " Enabled" |
    (.spec.customresourcedefinitions.owned[] |
      select(.name == "workloadavailabilityconfigs.workloadavailability.medik8s.io") |
      .specDescriptors[] | select(.path == strenv(WAO_COMPONENT_PATH) + ".manager") |
      .displayName) = strenv(WAO_COMPONENT_NAME) + " Manager" |
    (.spec.customresourcedefinitions.owned[] |
      select(.name == "workloadavailabilityconfigs.workloadavailability.medik8s.io") |
      .specDescriptors[] | select(.path == strenv(WAO_COMPONENT_PATH) + ".manager.resources") |
      .displayName) = strenv(WAO_COMPONENT_NAME) + " Manager Resources"
  ' "$csv"
done < <("$YQ" -r '
  .spec.customresourcedefinitions.owned[] |
  select(.name == "workloadavailabilityconfigs.workloadavailability.medik8s.io") |
  .specDescriptors[] | select(.path | test("^components\.[^.]+$")) |
  [.path, .displayName] | @tsv
' "$csv")

"$YQ" -i '
  (.spec.customresourcedefinitions.owned[] |
    select(.name == "workloadavailabilityconfigs.workloadavailability.medik8s.io") |
    .specDescriptors) |= sort_by(.path)
' "$csv"
