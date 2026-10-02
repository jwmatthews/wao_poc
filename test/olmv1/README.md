# OLM v1 (ClusterExtension) experiments

Scripts for installing the six RHWA operators through OLM v1 `ClusterExtension` and
exercising their admission webhooks. They mutate a real cluster, so read
[AGENTS.md](../../AGENTS.md) first. Same conventions as [test/cluster](../cluster/README.md):
every command passes `--kubeconfig` explicitly, raw output goes to the git-ignored
`evidence/<UTC-date>-olmv1-<exp>/`, admission is probed with `--dry-run=server` only, Secret
values are never captured.

## Experiment 0001: install via ClusterExtension and exercise every webhook

Question: do the shipped downstream RHWA bundles install through `ClusterExtension` on OCP 4.22,
and do their webhooks admit and reject correctly under OLM v1's Service CA certificate injection?

| Script | Step | Mutates |
| --- | --- | --- |
| `00-preflight.sh` | cluster is 4.22, OLM v1 serving the Red Hat catalog, no RHWA present | no |
| `01-namespace.sh` | create `openshift-workload-availability` with privileged PSA labels | namespace |
| `gen-installer-rbac.py` | generate installer SA/ClusterRole/ClusterRoleBinding and ClusterExtension per operator into `rbac/<key>/` from the shipped CSVs | no (files) |
| `02-install.sh KEY` | apply installer RBAC and ClusterExtension; wait for Installed; record rendered CRDs, Deployment, Services, webhook configs, cert volumes | installer RBAC, ClusterExtension and everything it renders |
| `03-webhooks.sh KEY` | dry-run every (CRD, verb) in `samples/matrix.yaml` for that operator; compare to expected admit/reject | no (dry-run only) |
| `04-restart.sh KEY` | restart the manager, re-probe webhooks | pod restart |
| `18-uninstall.sh` | delete ClusterExtensions (**deletes CRDs**), installer RBAC, namespace | everything above |

Operator keys and pinned versions are in `env.sh`. Install order is NHC, NMO, MDR, FAR, SBR, SNR;
SNR last because enabling it starts node agents on every eligible node (all three nodes on the
dev cluster are control-plane nodes).

```sh
export KUBECONFIG=/path/to/disposable.kubeconfig   # jmatthews0929a for experiment 0001
bash test/olmv1/00-preflight.sh
bash test/olmv1/01-namespace.sh
.venv/bin/python test/olmv1/gen-installer-rbac.py
for k in nhc nmo mdr far sbr snr; do bash test/olmv1/02-install.sh $k && bash test/olmv1/03-webhooks.sh $k && bash test/olmv1/04-restart.sh $k; done
```

Outcomes accumulate in `$RUN_DIR/outcomes.tsv`. After a run, write a sanitized `RESULTS.md`
in the run directory and summarize it in the private planning repo's experiment record.

## Why the installer RBAC is generated

OLM v1 has no OperatorGroup and no built-in installer identity: every `ClusterExtension` names
a ServiceAccount that must already hold RBAC for every object the bundle renders, including
CRDs, ClusterRoles, the controller's own permissions (the installer must be able to grant them),
webhook configurations, and `clusterextensions/finalizers`. `gen-installer-rbac.py` derives
that from each CSV following the OCP 4.22 "Creating a cluster role for an extension"
procedure. The result is deliberately broad in places (names OLM generates cannot be
predicted); it is an experiment input, not product RBAC. Measuring how much RBAC this takes
per operator is one of the experiment's outputs.

## Experiment 0002: release a ClusterExtension's CRD without losing its CRs

`exp0002.sh STEP` (1 baseline, 2 same-package collision, 3 naive delete, 4 MODE protection variants
with `CASCADE=orphan|background`, 5 restore-then-install, 6 verify, cleanup). Run 2026-10-02:
normal deletion removes CRDs and CRs (ownerReference garbage collection); metadata protection is
undone by reconcile; `--cascade=orphan` preserves every rendered object; a pre-existing object is
adopted when it carries `meta.helm.sh/release-name=<extension>`, `meta.helm.sh/release-namespace`
and `app.kubernetes.io/managed-by=Helm`. See the sanitized `RESULTS.md` kept with the run.

## Experiment 0003: WAO adopts the twelve CRDs from six installed extensions

`exp0003.sh STEP` (1 baseline, 2 orphan-delete the six, 3 delete old managers/webhooks/RBAC by
owner-name label, 4 re-annotate the CRDs for WAO's release, 5 install WAO, 6 enable NHC and SNR,
7 verify UIDs and admission). Needs the WAO bundle as an OLM v1 catalog: build `bundle.Dockerfile`
as a binary build in `wao-poc-build`, write an FBC (`olm.package`, `olm.channel`, `olm.bundle` with
`olm.package` and `olm.gvk` properties and the bundle image digest) under `configs/`, build a
`FROM scratch` catalog image with `LABEL operators.operatorframework.io.index.configs.v1=/configs`,
grant `system:image-puller` on the build namespace to `system:serviceaccounts:openshift-catalogd`
and `system:serviceaccounts:openshift-operator-controller`, and create a `ClusterCatalog` named
`wao-poc` (the name `gen-installer-rbac.py` pins in the `wao` ClusterExtension selector). Run
2026-10-02: pass; all twelve CRDs and CRs preserved; the SNR agent DaemonSet was rolled because
the operand image differed from the installed one.
