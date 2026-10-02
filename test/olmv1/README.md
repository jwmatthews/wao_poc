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
