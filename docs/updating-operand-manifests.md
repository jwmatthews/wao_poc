# Updating operand manifests

The Workload Availability Operator (WAO) copies each operand's local `config/` directory.
An operand is a component operator that WAO installs.
WAO applies its own Kustomize overlays to the copy.

An overlay selects resources or applies changes to a base configuration.
See [Operand configuration and Kustomize overlays](operand-config-overlays.md) for details.

The update procedure has four stages:

1. Select the source directories, branches, and image tags in [operands.yaml](../operands.yaml).
2. Update the copied configuration.
3. Generate the runtime objects.
4. Generate the bundle when you are ready to package WAO.

Run all commands from the WAO repository root.
Git, Bash, Make, Go, and jq must be available.
Make installs yq, Kustomize, and the packaging tools when a target requires them.

## Quick start

1. Edit `operands.yaml`. Set the checkout paths, expected branches, image repositories, and image tags.

2. Copy one operand's configuration. The command also synchronizes its image settings.

   ```sh
   make update-nhc-manifests
   ```

3. Generate runtime YAML from WAO's copied configuration.

   ```sh
   make operand-manifests
   ```

4. Review the changes.

   ```sh
   git status --short
   git diff
   ```

5. Generate normalized bundle content when you are ready to package WAO.

   ```sh
   make bundle-reset
   ```

6. Check that the generated files match their inputs.

   ```sh
   make check
   ```

7. Run the offline regression tests.

   ```sh
   make test-offline
   ```

To update all six operands, use `make update-operand-manifests` instead of `make update-nhc-manifests`.
Configure all six checkout paths and branches first.

## Configure the source and images

Edit the existing entries in `operands.yaml`.
For example, the NHC entry contains:

```yaml
operands:
  nhc:
    source:
      path: ../node-healthcheck-operator
      branch: main
    images:
      RELATED_IMAGE_NHC_MANAGER:
        repository: quay.io/medik8s/node-healthcheck-operator
        tag: latest
      RELATED_IMAGE_NHC_CONSOLE:
        repository: quay.io/medik8s/node-remediation-console
        tag: latest
```

Keep the other operand entries in the file.
Use the following rules for each field.

### Source path

Set `source.path` to the root of the operand's Git repository.
Relative paths start at WAO's repository root.
Absolute paths are also permitted.

Use an explicit path.
The helper does not expand `~` or `$VARIABLE` in YAML.

### Source branch

Set `source.branch` to the active branch in the operand repository.
The helper checks the branch name.
It does not change the checkout.

The copy includes uncommitted and untracked files under `config/`.
The helper also supports Git worktrees.

### Image repository and tag

Set `images.*.repository` and `tag` separately.
The helper uses tags such as `latest`, `wao`, and `v0.12.0` exactly as written.
Each image has an independent selection, including the NHC console and SBR agent.

The runtime overlays in `config/operands/<key>/overlays/runtime/` insert `__WAO_<ENV>__:placeholder` tokens into the generated objects.
During reconciliation, the operator replaces these tokens with its `RELATED_IMAGE_*` values.
Reconciliation is the process in which the operator applies the requested configuration to cluster resources.

A tag change does not change the runtime overlays.

The helper trusts the selected source and image combination.
Copying and generating manifests do not require any of the following:

- A published image
- Registry access
- Image digest resolution
- Identification of the source commit

The selected images must be available when you run the operands.

If you changed only the image selections, run `make operand-manifests` directly.
Update the source copy when you need configuration changes from an operand checkout.

## Choose the update target

Each of these targets updates one operand:

```sh
make update-nhc-manifests
make update-snr-manifests
make update-sbr-manifests
make update-far-manifests
make update-mdr-manifests
make update-nmo-manifests
```

To update all operands, use:

```sh
make update-operand-manifests
```

The combined target checks all selected inputs before it replaces any copied configuration.
It processes the six operands in sequence, even with parallel Make.

Use the combined target to update all operands.
Do not run individual update targets together with `make -j`.
Those targets modify the same manager YAML file.

## Expected results

An update prints one line for each copied operand.
For example:

```text
== nhc: copying config/ from the selected working tree
```

Each command has a separate result:

| Command | Expected changes |
| --- | --- |
| `make update-nhc-manifests` | The command replaces `config/operands/nhc/config/`. It synchronizes NHC `RELATED_IMAGE_*` values in `config/manager/manager.yaml`. |
| `make update-operand-manifests` | The command applies the same update to all six operands. |
| `make operand-manifests` | The command synchronizes all `RELATED_IMAGE_*` values. It generates `internal/operands/manifests/<key>/objects.yaml`. |
| `make bundle-reset` | The command generates and normalizes `bundle/` from copied CRDs and WAO's packaging configuration. |

CRDs are custom resource definitions.

An update removes copied files that no longer exist in the upstream source.
It preserves the WAO directories `config/operands/<key>/overlays/{rbac,runtime}/`.
The update does not edit these overlays.

The update targets stop after copying the configuration and synchronizing the image settings.
Runtime generation uses the configuration that WAO already contains.
It does not require an operand checkout.

The update and generation commands do not perform these actions:

- Generate a bundle
- Apply resources to a cluster
- Enable a component

If you repeat a command with identical inputs, it may produce no differences.

The Make targets `manager`, `run`, `docker-build`, and shared `dev-build` run `operand-manifests` before compilation.
Before a direct `podman build` or `docker build`, run `make operand-manifests`.

## Review the changes

Review these files and settings:

- `operands.yaml`
- The copied configuration
- The image settings
- The generated runtime objects
- Any subsequent bundle changes

Exclude machine-specific checkout paths from shared changes unless you intend to share those paths.
Apply WAO integration changes through its overlays.
A subsequent update replaces files in the copied `config/` directory.

The `make verify-operand-manifests` command checks the generated files as follows:

1. It copies the existing files to a temporary directory.
2. It generates the files again in the same locations.
3. It compares the generated files with the original copies.
4. It reports any differences.
5. It restores the original files where the generated files differ.

The command also checks the RBAC resources and bundle structure.
RBAC means role-based access control.
These resources define the permissions for the operand ServiceAccounts.

The `make test` command separately checks that the bundle matches its inputs.
It requires a clean checkout.
See [AGENTS.md](../AGENTS.md) for the complete commit and test procedure.

## Correct errors

| Error | Action |
| --- | --- |
| Missing checkout, incorrect Git root, or missing `config/` | Set `source.path` to the root of a local operand repository that contains `config/`. |
| Branch mismatch or detached HEAD | Switch the operand repository to the intended branch. Alternatively, correct `source.branch`. |
| Invalid image input, or missing or duplicate image destination | Check the repository and tag fields. Check the specified `RELATED_IMAGE_*` entry in `config/manager/manager.yaml`. |
| Kustomize failure, an unreplaced placeholder, or an image field without a WAO placeholder | Check for upstream changes to files, resource names, or image names. Adjust WAO's overlays as required. |

If an input or branch check fails, the helper does not replace the copied configuration.
After you correct an error, run the affected update or generation command again.
Review any generated changes that remain from an earlier attempt.
