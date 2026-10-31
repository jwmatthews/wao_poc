#!/usr/bin/env bash
set -euo pipefail

# Post-process the generated base CSV so the OpenShift console labels each
# component's controls. Runs in `make bundle` after
# `operator-sdk generate kustomize manifests`. It edits only specDescriptors
# (console labels and widgets). It never changes the CRD schema or validation.
#
# Why markers cannot do this:
# - All six components share the ComponentSpec and CPUMemory Go types, so a
#   marker produces the same label for each one: six switches named "Enabled",
#   six groups named "Manager Resources".
# - operator-sdk does not generate descriptors below manager.resources, so the
#   CPU and memory fields get no text control or help text without this script.
#
# What it does for each component found under components.<key>:
# - Prefixes the Enabled, Manager and Manager Resources labels with the
#   component name, for example "Node Health Check Enabled".
# - Adds CPU/Memory Request/Limit text descriptors with examples and a note
#   that an empty field keeps the packaged default.
# - Sorts descriptors by path so each component's controls stay together.
#
# The console details page flattens nested descriptors, so a label without the
# component name does not say which component it controls.
#
# TestResourceConfigurationSchemaAndConsole (test/offline) pins the output.
# Update that test if you change labels or controls here.
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
        map(select(.path | test("^" + strenv(WAO_COMPONENT_PATH) + "\\.manager\\.resources\\.(requests|limits)\\.(cpu|memory)$") | not)) +
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
           "x-descriptors": ["urn:alm:descriptor:com.tectonic.ui:text"]}
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
