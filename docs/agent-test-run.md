# Agent runbook: full install test on a new cluster

This is a step-by-step guide for a coding agent to run the complete live-cluster install
verification (cases WAO-INST-00 through WAO-INST-18) against an OpenShift cluster that has
never had WAO built on it. Read [AGENTS.md](../AGENTS.md) first; its constraints apply to
every step here. Facts about the harness itself live in
[test/cluster/README.md](../test/cluster/README.md).

## Scripted path

Sections 1 through 7 are automated by `test/cluster/full-run.sh`. After section 0, run:

```sh
CONFIRM=yes KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/full-run.sh
```

It stops at the first failed phase, writes everything to `evidence/<UTC-date>-wao-poc/`, and ends
with a `REPORT.md` skeleton and the suggested commit command. The sections below explain what it
does and what to do when a phase fails. Section 0 and section 8 remain the agent's job.

## 0. Before touching any cluster

1. **Get explicit confirmation** from the person you are working for of which cluster to use,
   in the current session. Do not infer it from a previous session, from memory, or from
   `DISPOSABLE_OPENSHIFT_CLUSTERS.md` alone. That file lists candidates; it is not consent.
2. The cluster must be **disposable** and one they are authorized to modify. The run starts
   privileged node agents (SNR) on every node and deletes CRDs during cleanup.
3. Set `KUBECONFIG` to the cluster's kubeconfig path and pass it explicitly on every command.
   Never rely on the current context.

```sh
export KUBECONFIG=/path/to/disposable.kubeconfig   # outside the repo, or matched by .gitignore
oc whoami --kubeconfig "$KUBECONFIG"                # confirms the credential works
```

Stop immediately if any of the following is true, and report it instead of proceeding:

- The person has not named the cluster in this session.
- The cluster hosts anything that is not disposable.
- `oc whoami` fails or shows an unexpected user.

## 1. Workstation prerequisites

Run from the repository root on the branch you want to test.

```sh
python3 -m venv .venv && .venv/bin/pip install -r hack/requirements.txt
make bundles                   # pinned upstream bundles into .cache/bundles, digests verified
make operand-manifests-check   # committed manifests match the bundles
make test                      # Go unit and envtest suites (downloads envtest into bin/)
make test-offline              # Python tests and bash -n on the cluster scripts
```

All four must pass before a cluster run. If `make test` fails, fix or report that first;
a cluster run cannot be interpreted on top of a broken build.

Tools needed on PATH: `go`, `oc`, `python3`, `bash` 3.2 or later. `make bundle` downloads
`operator-sdk`, `kustomize` and `controller-gen` into `bin/` on first use.

## 2. Check the cluster is suitable (read-only)

Preflight is read-only and checks everything the harness needs: supported control-plane
topology, all nodes `linux/amd64`, classic OLM present, no medik8s CRDs or CSVs, the install
namespace absent, and the WAO image present in the internal registry.

```sh
bash test/cluster/run-all.sh 00
```

On a new cluster the **image check fails**, because the committed bundle references an image
digest in a different cluster's internal registry. Every other check should pass. If a
different check fails, resolve it before continuing:

| Failure | What to do |
| --- | --- |
| medik8s CRDs or CSVs exist | Uninstall the standalone medik8s operators and delete their CRDs. Ask before deleting anything on a cluster you were not told is clean. |
| namespace `openshift-workload-availability` exists | A previous run did not clean up. Run `bash test/cluster/run-all.sh 18` and re-run preflight. |
| topology unsupported or nodes not amd64 | The cluster cannot be used. Report it. |
| classic OLM absent | The cluster cannot be used with this harness. The OLM v1 experiments in `test/olmv1/` are a separate path. |

Preflight appends the OpenShift version, node count and topology to `evidence/<date>-wao-poc/RUN.md`.

## 3. Build the WAO image on the cluster

The image is built in the cluster's internal registry in its own namespace `wao-poc-build`.
No external registry or credentials are needed. The build uploads a clean `git archive` of
`HEAD`, never the working directory, so git-ignored files such as kubeconfigs never leave the
workstation. Commit or stash anything you want included before this step.

```sh
SRC=$(mktemp -d) && git archive HEAD | tar -x -C "$SRC"

oc create namespace wao-poc-build --kubeconfig "$KUBECONFIG"
oc new-build --binary --name wao -n wao-poc-build --strategy docker --kubeconfig "$KUBECONFIG"
oc policy add-role-to-group system:image-puller \
  system:serviceaccounts:openshift-workload-availability -n wao-poc-build --kubeconfig "$KUBECONFIG"
oc start-build wao -n wao-poc-build --from-dir="$SRC" --follow --kubeconfig "$KUBECONFIG"

DIGEST=$(oc get istag wao:latest -n wao-poc-build --kubeconfig "$KUBECONFIG" -o jsonpath='{.image.metadata.name}')
echo "$DIGEST"   # sha256:...
```

The `image-puller` grant is applied before the install namespace exists; that is intended and
works. If `wao-poc-build` already exists from an earlier run on this cluster, skip the
`create namespace` and `new-build` lines and go straight to `start-build`.

The build takes several minutes. If it fails, read the build log with
`oc logs -f bc/wao -n wao-poc-build` and report the failure; do not retry blindly.

## 4. Point the bundle at the new image and render the catalog

```sh
IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@$DIGEST
make bundle IMG=$IMG VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
make bundle-check
make catalog-configmap DEFAULT_CHANNEL=alpha   # writes dist/wao-poc-catalog.yaml (git-ignored)
```

`make bundle` rewrites tracked files under `bundle/`. Confirm the only change is the image
digest:

```sh
git diff --stat
git diff bundle/manifests/workload-availability-operator.clusterserviceversion.yaml | grep '^[-+] '
```

Expect the container `image` line and the `createdAt` timestamp in the CSV, and the image
digest in `config/manager/kustomization.yaml`. Also update the digest quoted in the
"Operator image and POC catalog" section of `README.md` by hand. Any other diff means
something else changed and must be understood before continuing. Do not commit the bundle
change yet; see section 8.

Re-run preflight. It must now pass cleanly, including the image check:

```sh
bash test/cluster/run-all.sh 00
```

## 5. Run the full case list

```sh
bash test/cluster/run-all.sh
```

This runs cases 00 through 18 in order and takes roughly 30 to 45 minutes, most of it waiting
for managers and CA injection. What it does, in order:

- 01 applies the ConfigMap-backed CatalogSource `wao-poc-catalog` in `openshift-marketplace`.
- 02 creates the namespace, OperatorGroup and Subscription, and approves the InstallPlan.
- 03 and 04 verify the clean-install invariants and the default all-Disabled config.
- 05 to 10 enable NHC, SNR, SBR, FAR, MDR and NMO one at a time. **06 starts privileged SNR
  agents on every eligible node.**
- 11 checks parity between the rendered operands and the upstream bundles.
- 12 and 13 restart WAO and repair deliberate drift.
- 14 to 17 disable everything and delete the config.
- 18 uninstalls WAO, removes the thirteen CRDs and the SNR leftovers, and deletes the namespace
  and catalog. It keeps `wao-poc-build` on purpose and reports it as a `LEFTOVER`.

Rules while it runs:

- Do not run other `oc` commands that mutate the cluster in parallel.
- Admission is probed only with server-side dry-run. Never create a real `NodeHealthCheck`,
  `StorageBasedRemediationConfig`, `NodeMaintenance` or remediation request to "help" a case.
- Never change a webhook `failurePolicy`.
- Never read Secret values. The harness only checks key names.

Failure policy is built into the script: a failed preflight stops before any change; a failed
01 or 02 marks 03 to 17 blocked and goes straight to cleanup; other failures are recorded and
the run continues; 18 always runs last.

Useful variants:

```sh
SKIP_CLEANUP=1 bash test/cluster/run-all.sh      # leave the cluster installed for inspection
bash test/cluster/run-all.sh 18                  # clean up later
STOP_ON_FAIL=1 bash test/cluster/run-all.sh      # block remaining cases after the first failure
bash test/cluster/run-all.sh 05 06               # re-run specific cases into the same RUN_DIR
```

Re-running a subset keeps earlier outcomes in the same evidence directory, so a run can be
resumed after fixing a problem. Note that cases assume the state left by the previous case;
re-running 05 after 18 has cleaned up will fail for that reason, not because of a bug.

## 6. Read the results

Everything the run wrote is under `evidence/<UTC-date>-wao-poc/`, which is git-ignored:

| Path | Contents |
| --- | --- |
| `results.json` | One entry per case: `id`, `status` (`pass`, `fail`, `blocked`), `observed_at`, `notes` |
| `cases/WAO-INST-NN.json` | The same, per case |
| `raw/case-NN.log` | Full stdout and stderr of each case script |
| `raw/*.json` | One file per recorded `oc` call, dry-run admission responses, parity diffs |
| `RUN.md` | Intended mutations, cleanup, and the preflight facts |

```sh
python3 test/cluster/results.py build --run-dir evidence/<UTC-date>-wao-poc   # prints id, status, notes per case
```

For every `fail`, open `raw/case-NN.log` and find the `FAIL:` or `TIMEOUT:` line. Compare
against the known upstream defect before blaming WAO: on the recorded runs, WAO-INST-09 and
WAO-INST-12 failed only because the upstream MDR manager cannot start under its 30Mi memory
limit, which reproduces without WAO (see [MDR_MEMORY_LIMIT_ISSUE.md](../MDR_MEMORY_LIMIT_ISSUE.md)).
Any other failure is new and needs a root cause, not a workaround in the test.

A `LEFTOVER:` note from case 18 for `wao-poc-build` is expected. Any other leftover means
cleanup is incomplete; list it in the report.

## 7. Write the report

Write `REPORT.md` next to `results.json` with:

- OpenShift version, node count and topology, copied from `RUN.md`. No cluster name.
- The image digest built in section 3.
- The pass/fail/blocked count and a one-line note per non-passing case, with the root cause
  if known and a pointer to the matching known issue.
- Any leftover objects after cleanup.
- Deviations from this runbook (skipped steps, manual interventions, re-runs).

The report must contain **no** API server URLs, cluster or node names, IP addresses, object
UIDs or Secret data. Check it before it leaves the evidence directory:

```sh
grep -nE 'https?://|:6443|\.apps\.|\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}' evidence/*-wao-poc/REPORT.md
```

An empty result is the goal. Node names found with `oc get nodes` must also be absent.

## 8. What to commit, and what never to commit

Commit, after the person has reviewed them:

- The bundle image update from section 4, as its own commit:
  `wao: point bundle at rebuilt image <first 12 hex of digest>`.
- Sanitized copies of `results.json` and `REPORT.md`, for example under `docs/results/`,
  only if asked.
- Any WAO fix made in response to a real failure, with a test, as a separate `wao:` commit.
  Run `make test` and `make test-offline` before each commit.

Never commit:

- Anything under `evidence/`, `.cache/`, `.venv/`, `dist/` or `bin/`.
- Any kubeconfig or `DISPOSABLE_OPENSHIFT_CLUSTERS.md`.
- Raw `oc` output of any kind.

Do not push unless told to.

## 9. Leaving the cluster

After case 18 the cluster passes preflight again except for the deliberately kept
`wao-poc-build` namespace, which holds the built image for the next run. Confirm with:

```sh
bash test/cluster/run-all.sh 00
```

If the person wants the cluster fully clean, delete `wao-poc-build` as well; the next run will
then need a fresh build from section 3.

## Quick reference

```sh
# prerequisites
python3 -m venv .venv && .venv/bin/pip install -r hack/requirements.txt
make bundles operand-manifests-check test test-offline

# cluster (confirmed disposable, named by the person in this session)
export KUBECONFIG=/path/to/disposable.kubeconfig
bash test/cluster/run-all.sh 00                    # expect only the image check to fail on a new cluster

# build on cluster
SRC=$(mktemp -d) && git archive HEAD | tar -x -C "$SRC"
oc create namespace wao-poc-build --kubeconfig "$KUBECONFIG"
oc new-build --binary --name wao -n wao-poc-build --strategy docker --kubeconfig "$KUBECONFIG"
oc policy add-role-to-group system:image-puller system:serviceaccounts:openshift-workload-availability -n wao-poc-build --kubeconfig "$KUBECONFIG"
oc start-build wao -n wao-poc-build --from-dir="$SRC" --follow --kubeconfig "$KUBECONFIG"
DIGEST=$(oc get istag wao:latest -n wao-poc-build --kubeconfig "$KUBECONFIG" -o jsonpath='{.image.metadata.name}')

# bundle and catalog
make bundle IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@$DIGEST VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
make bundle-check && make catalog-configmap DEFAULT_CHANNEL=alpha
bash test/cluster/run-all.sh 00                    # must pass cleanly now

# full run and results
bash test/cluster/run-all.sh
cat evidence/*-wao-poc/results.json
```
