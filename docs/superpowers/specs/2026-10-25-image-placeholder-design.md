# Placeholder image references

Status: proposed 2026-10-25. Follows the adversarial review of `make operand-manifests` and
`hack/generate-image-bindings.sh`. Supersedes the "generated image matching references" part of
`2026-10-24-simplify-operand-updates-design.md`; everything else in that design stands.

## Problem

The embedded runtime objects carry the real tagged image reference (`quay.io/medik8s/x:wao`).
The renderer must therefore know that exact string to replace it with the `RELATED_IMAGE_*` value
from its environment. That string is kept in five places (operands.yaml, manager.yaml, the runtime
kustomization, the SNR/SBR env patches, and a bash-generated Go map) and aligned by two scripts, a
verifier and a Go test. The whole-document substring replace also breaks if two bindings share a
reference or one tag is a prefix of another, and a missing map entry panics the manager at reconcile.

## Decision

Treat images like the namespace: bake a stable sentinel into the embedded objects and let the
renderer swap it for the runtime value.

- Sentinel: `__WAO_<ENV>__:placeholder`, for example `__WAO_RELATED_IMAGE_NHC_MANAGER__:placeholder`.
  Defined once, `images.Placeholder(env)`. Confirmed kustomize's `images` transformer emits it
  unchanged with `newName: __WAO_RELATED_IMAGE_NHC_MANAGER__` and `newTag: placeholder`.
- Runtime overlays and the SNR/SBR env patches become static WAO configuration. Nothing syncs them.
- `components.Definition.Images` is `[]string` of env names. `ImageBinding`, `imageBinding`, the
  panic and `internal/components/zz_generated.images.go` are deleted, as is
  `hack/generate-image-bindings.sh`.
- The renderer errors on any remaining `__WAO_` token after substitution (namespace or image).
- `make operand-manifests` fails if an embedded `image:` field is not a placeholder, so an upstream
  container that WAO does not map cannot silently deploy an upstream default.
- `operands.yaml` keeps `source` and `images.<ENV>.{repository,tag}` and drops `kustomizeName`.
  It feeds exactly one destination: the `RELATED_IMAGE_*` env values in `config/manager/manager.yaml`,
  which operator-sdk lifts into CSV `relatedImages`. This is the OADP pattern.
- The list of required images lives once, in `internal/images.Required`. A Go test checks that
  `operands.yaml` declares exactly that set; the bash validator no longer hardcodes it.
- `hack/verify-operand-manifests.sh` restores the pre-regeneration files when it reports drift, so
  `make check` leaves the tree as it found it.

## Unchanged

`RELATED_IMAGE_*` at runtime, `images.FromEnv`, `:latest` pull-policy handling, the copy workflow in
`hack/update-operand-manifests.sh`, the repository/tag validation rules, and all hard constraints
in AGENTS.md.
