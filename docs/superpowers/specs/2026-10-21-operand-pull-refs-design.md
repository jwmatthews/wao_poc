# Operand image pull references

## Decision

Replace each image's `pinned` field in `release-set.yaml` with `pullRef`, the exact reference WAO deploys. The selected tag determines the reference: exactly `latest` stays a floating tag; every other tag resolves to an immutable SHA-256 digest. The user accepted the `pullRef` name on 2026-10-21.

This addresses development images whose manifests become unavailable after upstream moves `latest` and the registry garbage collects the untagged image. Release images retain digest pinning.

## Release set contract

Keep `repo`, `tag`, `commit`, `overlay`, `resolvedAt`, `tagged`, and `kustomizeName` with their existing roles. Rename `images.<ENV>.pinned` to `images.<ENV>.pullRef`.

For development:

```yaml
tag: latest
images:
  RELATED_IMAGE_NHC_MANAGER:
    tagged: quay.io/medik8s/node-healthcheck-operator:latest
    pullRef: quay.io/medik8s/node-healthcheck-operator:latest
    kustomizeName: quay.io/medik8s/node-healthcheck-operator
```

For a release, `tagged` uses the chosen release tag and `pullRef` is the same repository followed by `@sha256:` and 64 lowercase hexadecimal characters.

Reject missing references, mismatched repositories, tagged references inconsistent with the component tag, digest references for latest, and floating references for any other tag. Do not fall back silently to `tagged` if a release digest is missing. Remove legacy `pinned` fields; the repository has no external release-set compatibility contract requiring dual reads.

## Tag selection

Keep the existing precedence: component override such as `NHC_TAG`, then `OPERAND_TAG`. Preserve Make's `latest` default and the standalone script's existing `release` default.

Resolve the special selectors before applying the reference policy:

| Selection | Effective behavior |
| --- | --- |
| `latest` | Use `repository:latest` for all images of the component |
| `release` | Discover the GitHub release tag and resolve image digests |
| Explicit non-latest tag | Resolve image digests |
| `pinned` | Keep the component's recorded tag, refresh its metadata, and apply the same reference policy |

The selector `pinned` continues to mean keeping current tags, not freezing a moving latest image. Console and agent images follow their component's selection, including mixed latest and release components.

## Resolution and source provenance

Continue reading `version.GitCommit` from published images and copying upstream manifests at that commit. Keep the checks that images embedding a commit agree within a component, that at least one image supplies the commit, and that pull or extraction failures stop the workflow.

For latest, extract the commit from the tagged image without requiring a separate digest-resolution step. For other tags, resolve the digest first and extract the commit through that digest, avoiding a second read through a potentially moving tag.

For latest, the commit and `VENDORED.yaml` identify the manifest snapshot at bump time. They cannot guarantee that a future pull of latest runs the same code. Refresh operands again to update that snapshot. No observed digest is needed as persistent metadata for this change.

## Generation and runtime

Use one shared offline validator that emits environment-variable names and `pullRef` values for both Make generation and verification. Validate the complete release set before updating manager environment variables. Diagnostics identify the component and image variable.

Keep `tagged` as the image matching key in runtime overlays and generated Go bindings. Populate the WAO manager's `RELATED_IMAGE_*` values from `pullRef`; the existing renderer substitutes those values in manager images, console images, and agent image environment variables. The status image strings continue to report configured references; no API field or schema shape changes.

For the operand Deployment containers that use a configured latest reference, explicitly render `imagePullPolicy: Always`. This covers existing Deployments originally defaulted to `IfNotPresent`. Apply the policy only to matching operand images, including init containers if present; preserve unrelated images and existing release-image policies. Agent images passed through environment variables use latest, but their pod creation and pull policies remain controlled by the unchanged upstream operators.

`Always` checks the registry when a container starts. It does not restart running containers when a tag moves. Automatic rollout or tag watching is outside this change.

Reference: [Kubernetes 1.33 image pull policy](https://v1-33.docs.kubernetes.io/docs/concepts/containers/images/#image-pull-policy). The project uses `k8s.io/api v0.33.0`; its dependency source also documents these defaults. Context7's indexed website versions did not include 1.33, so versioned official documentation was used.

## Migration and documentation

Migrate existing entries without inventing new provenance: latest entries take `pullRef` from `tagged`; non-latest entries take it from the existing `pinned` digest. Keep commits and timestamps unchanged during this schema-only migration. A subsequent explicit bump refreshes upstream content.

Regenerate manager configuration and the OLM bundle using existing targets. Do not hand-edit generated bundle files or modify vendored operator source. Update the hard constraint in `AGENTS.md` to require the references recorded in the release set, with floating latest and digest-pinned other tags. Update active README and code comments; historical archived designs retain their historical descriptions.

## Validation and limits

Offline tests cover selector resolution, mixed components, latest/release transitions, removal of stale `pinned` fields, missing and malformed references, repository mismatches, generated output consistency, rendered image substitutions, pull policies, and unchanged webhook failure policies. Stub network commands in resolver tests. CI must not query Quay or GitHub.

Use `make operand-manifests`, `make bundle-reset`, focused Go tests, and `make check` during implementation. Before pushing, run `make test-offline` and `make test` on a clean tree as required by `AGENTS.md`. No cluster work is required or authorized for this task.

All components still default to Disabled. No public image override is added. Operand operators remain unchanged; foreign-object ownership and webhook behavior remain unchanged. Durable development-image retention, other floating tags, automatic restarts, and disconnected release packaging are outside scope.
