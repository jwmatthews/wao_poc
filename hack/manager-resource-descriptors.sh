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
      .displayName) = strenv(WAO_COMPONENT_NAME) + " Manager Resources" |
    (.spec.customresourcedefinitions.owned[] |
      select(.name == "workloadavailabilityconfigs.workloadavailability.medik8s.io") |
      .specDescriptors) |= (
        map(select(.path != strenv(WAO_COMPONENT_PATH) + ".manager.resources.claims" and
          (.path | test("^" + strenv(WAO_COMPONENT_PATH) + "\\.manager\\.resources\\.(requests|limits)\\.(cpu|memory)$") | not))) +
        [
          {"path": strenv(WAO_COMPONENT_PATH) + ".manager.resources.requests.cpu",
           "displayName": strenv(WAO_COMPONENT_NAME) + " CPU Request",
           "description": "Set the manager CPU request, for example 100m or 1. Leave empty to use the packaged default.",
           "x-descriptors": ["urn:alm:descriptor:com.tectonic.ui:text"]},
          {"path": strenv(WAO_COMPONENT_PATH) + ".manager.resources.requests.memory",
           "displayName": strenv(WAO_COMPONENT_NAME) + " Memory Request",
           "description": "Set the manager memory request, for example 128Mi or 1Gi. Leave empty to use the packaged default.",
           "x-descriptors": ["urn:alm:descriptor:com.tectonic.ui:text"]},
          {"path": strenv(WAO_COMPONENT_PATH) + ".manager.resources.limits.cpu",
           "displayName": strenv(WAO_COMPONENT_NAME) + " CPU Limit",
           "description": "Set the manager CPU limit, for example 500m or 1. Leave empty to use the packaged default.",
           "x-descriptors": ["urn:alm:descriptor:com.tectonic.ui:text"]},
          {"path": strenv(WAO_COMPONENT_PATH) + ".manager.resources.limits.memory",
           "displayName": strenv(WAO_COMPONENT_NAME) + " Memory Limit",
           "description": "Set the manager memory limit, for example 256Mi or 1Gi. Leave empty to use the packaged default.",
           "x-descriptors": ["urn:alm:descriptor:com.tectonic.ui:text"]},
          {"path": strenv(WAO_COMPONENT_PATH) + ".manager.resources.claims",
           "displayName": "Resource Claims",
           "x-descriptors": ["urn:alm:descriptor:com.tectonic.ui:hidden"]}
        ]
      )
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
