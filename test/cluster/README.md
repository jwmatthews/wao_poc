# Live-cluster install verification

Scripts for the install case in
[implementation-plan.md section 4](../../docs/implementation-plan.md#4-live-cluster-verification-install-case).
Each case `WAO-INST-NN` has one script `NN-<slug>.sh`. The scripts mutate a real cluster, so read
[AGENTS.md](../../AGENTS.md) first.

## Prerequisites

- A **disposable** OpenShift 4.x cluster with classic OLM that you are authorized to modify. Confirm which
  cluster to use with the person you are working for before every session.
- `linux/amd64` nodes and a control-plane topology NHC supports (`HighlyAvailable`, `SingleReplica`,
  `HighlyAvailableArbiter`, `External`).
- No medik8s operators or CRDs installed.
- The WAO image pullable by the cluster. The POC bundle points at the internal registry
  (`wao-poc-build/wao@sha256:…`); preflight checks the image stream image exists.
- `dist/wao-poc-catalog.yaml` from `make catalog-configmap`, `.cache/bundles/` from `make bundles`, and
  `.venv` with `hack/requirements.txt` (PyYAML, used by `parity.py`).
- `oc` (or `kubectl` via `OC=kubectl`) and `python3`. The scripts run under bash 3.2 or later. Run them with
  `bash`, not `zsh`.
- MDR needs the OpenShift Machine API to do anything useful. Its manager installs either way; preflight
  records whether the API is present.

Every command passes `--kubeconfig "$KUBECONFIG"` explicitly. The current context is never used.

## Running

```sh
KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/run-all.sh          # all cases, 00..18
KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/run-all.sh 00       # preflight only (read-only)
KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/05-enable-nhc.sh    # one case by hand
```

`run-all.sh` runs the cases in order, logs each to `raw/case-NN.log`, records an outcome per case and
writes `results.json`. A failed preflight stops before anything changes. A failed catalog or install
(01, 02) marks 03–17 `blocked` and goes straight to cleanup. Other failures are recorded and the run
continues. `STOP_ON_FAIL=1` blocks the remaining cases after the first failure. WAO-INST-18 always runs
last and returns the cluster to a state that passes preflight, unless `SKIP_CLEANUP=1` (leave the cluster
for inspection, then run `run-all.sh 18` later). Running a subset keeps earlier outcomes in the same
`RUN_DIR`, so a run can be resumed.

| Script | Case | Mutates |
| --- | --- | --- |
| `00-preflight.sh` | WAO-INST-00 preflight | no |
| `01-catalog.sh` | WAO-INST-01 catalog | CatalogSource and ConfigMap in `openshift-marketplace` |
| `02-install-wao.sh` | WAO-INST-02 install via OLM | namespace, OperatorGroup, Subscription, InstallPlan approval |
| `03-clean-install.sh` | WAO-INST-03 clean-install invariants | no |
| `04-default-config.sh` | WAO-INST-04 default config, status, CEL | no (dry-run only) |
| `05-enable-nhc.sh` | WAO-INST-05 enable NHC | config patch |
| `06-enable-snr.sh` | WAO-INST-06 enable SNR | config patch; **starts SNR agents on every eligible node** |
| `07-enable-sbr.sh` | WAO-INST-07 enable SBR | config patch |
| `08-enable-far.sh` | WAO-INST-08 enable FAR | config patch |
| `09-enable-mdr.sh` | WAO-INST-09 enable MDR, selector isolation | config patch |
| `10-enable-nmo.sh` | WAO-INST-10 enable NMO | config patch |
| `11-parity.sh` | WAO-INST-11 parity, all six | no |
| `12-restart.sh` | WAO-INST-12 restart idempotence | deletes the WAO pod |
| `13-drift.sh` | WAO-INST-13 drift repair | scales the SBR manager to 0 |
| `14-disable-sbr-far-mdr.sh` | WAO-INST-14 disable SBR, FAR, MDR | config patch |
| `15-disable-nmo-nhc.sh` | WAO-INST-15 disable NMO and NHC | config patch |
| `16-disable-snr.sh` | WAO-INST-16 disable SNR (manager level) | config patch |
| `17-delete-config.sh` | WAO-INST-17 delete the config | deletes the config and the WAO pod |
| `18-uninstall.sh` | WAO-INST-18 uninstall and cleanup | deletes everything above; stops SNR agents |

Cleanup keeps the image build namespace `wao-poc-build` on purpose and reports it as a `LEFTOVER`.

## full-run.sh: build, install, run

`full-run.sh [build|install|run|all]` wraps the cases for a cluster that has never had WAO built on it.
Every phase confirms the cluster first (`CONFIRM=yes` skips the prompt) and logs to `RUN_DIR/full-run.log`.

- `build`: workstation checks, preflight with the image check skipped (`SKIP_IMAGE_CHECK=1`), on-cluster
  image build from `git archive HEAD` into `wao-poc-build`, `make bundle` pointed at the new digest (it
  also updates the digest quoted in `README.md`), a guard that only those three tracked files changed,
  `make catalog-configmap`.
- `install`: `run-all.sh 00 01 02`. Leaves WAO installed with every component Disabled and prints the
  next commands. Clean up with `run-all.sh 18`.
- `run`: `run-all.sh` (00..18), then a `REPORT.md` skeleton beside `results.json` with a sanitization grep.
- `all` (default): `build` then `run`.

```sh
CONFIRM=yes KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/full-run.sh build
CONFIRM=yes KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/full-run.sh install
```

Options: `SKIP_PREREQS=1`, `SKIP_BUILD=1` (reuse `istag wao:latest`), `ALLOW_DIRTY=1`, `WAO_VERSION`,
plus `STOP_ON_FAIL`, `SKIP_CLEANUP` and `RUN_DIR` from `run-all.sh`. It never commits or pushes.
See [docs/agent-test-run.md](../../docs/agent-test-run.md).

## Safety

- Admission is only ever probed with `--dry-run=server`. No `NodeHealthCheck`,
  `StorageBasedRemediationConfig`, `FenceAgentsRemediation`, `MachineDeletionRemediation`,
  `NodeMaintenance` or `SelfNodeRemediation` is created. The SNR config, template and Secret that SNR
  creates itself are expected (design brief D3).
- Secrets are only checked for existence and data key names (`secret_key_names`), never values.
- No script changes a webhook `failurePolicy`.

## Helpers (`lib.sh`)

`k`, `record NAME ARGS…`, `wait_for SECONDS DESCRIPTION COMMAND…`, `expect DESCRIPTION COMMAND…`,
`component_field KEY FIELD` and `snapshot LABEL` as in the plan, plus predicates that treat an API error
as a failure rather than as "absent": `jcheck PYEXPR ARGS…`, `found`, `none_found`, `absent`,
`ca_injected`, `secret_has_keys`, `operands_present DIR` and `operands_absent DIR` (every object WAO
renders for a component, from `internal/operands/manifests/DIR`), `labelled_absent KEY`,
`no_medik8s_webhooks` and `restart_wao`. Every case script exits non-zero on a failed expectation.

## Evidence and reporting

Raw output goes only to `evidence/<UTC-date>-wao-poc/` (override with `RUN_DIR`), which is git-ignored:

- `RUN.md`: intended mutations and cleanup (written by `run-all.sh`), plus preflight facts.
- `raw/`: one JSON file per `record` call, `case-NN.log`, dry-run admission responses, parity diffs.
  These contain API URLs, node names and addresses. Never commit them.
- `cases/WAO-INST-NN.json` and `results.json`: one entry per case with `id`, `status`
  (`pass`, `fail` or `blocked`), `observed_at` (UTC) and `notes`, written by `results.py`. Notes are the
  `FAIL:`, `TIMEOUT:`, `note:` and `LEFTOVER:` lines of the case log. Record a manual outcome with
  `python3 test/cluster/results.py record --run-dir DIR --id WAO-INST-NN --status blocked --notes "…"` and
  rebuild with `results.py build --run-dir DIR`.

After the run, write a short `REPORT.md` beside `results.json`. Only sanitized copies of `results.json`
and `REPORT.md` may be committed (for example under `docs/results/`), and only after review: no API
URLs, cluster or node names, IP addresses, UIDs or Secret data.

## Offline checks

`make test-offline` runs the parity checker's tests against the extracted manifests, the results
recorder's tests and `bash -n` on every script. No cluster is needed.
