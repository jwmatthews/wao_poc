# OLM v1 install manifests

`namespace.yaml` is hand-written. Everything under `wao/` is **generated** from the committed
bundle by `test/olmv1/gen-installer-rbac.py --only wao` (`make olmv1-manifests`); do not edit it,
regenerate it. `make olmv1-manifests-check` (part of `make test-offline`) fails when it is stale.

| File | Purpose |
| --- | --- |
| `namespace.yaml` | Install namespace with `openshift.io/node-selector: ""` and privileged PSA labels |
| `wao/00-serviceaccount.yaml` | Installer ServiceAccount `wao-installer` (D12) |
| `wao/10-clusterrole.yaml` | Everything OLM v1 renders from the bundle, following the OpenShift 4.22 "Creating a cluster role for an extension" procedure |
| `wao/20-clusterrolebinding.yaml` | Binds the ClusterRole to `wao-installer` |
| `wao/30-clusterextension.yaml` | `ClusterExtension` pinned to version `0.1.0`, channel `alpha`, catalog `wao-poc` |

The `ClusterCatalog` is not committed: its image reference is a per-cluster digest. Render it with
`make clustercatalog CATALOG_IMG=<catalog image>@sha256:…` into `dist/wao-poc-clustercatalog.yaml`.

On OpenShift 5.0 `spec.serviceAccount` is deprecated and ignored; applying the RBAC is harmless
there and still required on 4.18–4.22.
