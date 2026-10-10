# NHC OpenShift packaging inputs

Verbatim copies of upstream Node Health Check source files that the OpenShift (`bundle-ocp`)
packaging applies and the published bundles do not carry. `hack/extract-operand-manifests.py`
reads them and records their sha256 in `internal/operands/manifests/provenance.json`
(`bundles.nhc.platform_sources`). Never edit these files; replace them from a new pinned
commit and update `NHC_PLATFORM["commit"]` in the extractor.

Repository: https://github.com/medik8s/node-healthcheck-operator
Commit: `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f` (tag v0.12.0, the pinned manager image)

| File | Upstream path | Applied as |
| --- | --- | --- |
| `ca-configmap.yaml` | `config/optional/prometheus-ocp/ca-configmap.yaml` | `ConfigMap/node-healthcheck-ca-bundle`; service-ca injects `service-ca.crt` |
| `prometheus-k8s-role.yaml` | `config/optional/prometheus-ocp/prometheus-k8s-role.yaml` | `Role/node-healthcheck-prometheus-k8s` |
| `prometheus-k8s-rolebinding.yaml` | `config/optional/prometheus-ocp/prometheus-k8s-rolebinding.yaml` | `RoleBinding/node-healthcheck-prometheus-k8s`, subject `openshift-monitoring/prometheus-k8s` kept |
| `auth_proxy_service_patch.yaml` | `config/manifests/ocp/auth_proxy_service_patch.yaml` | labels and annotations merged into the metrics Service |
| `deployment_patch.yaml` | `config/manifests/ocp/deployment_patch.yaml` | `tls-config` volume and mount added to the manager; args and ports must equal the bundle's |

Upstream renders these through kustomize with `namePrefix: node-healthcheck-` and namespace
`system`; the extractor applies the prefix and WAO's namespace placeholder. The overlay's
`kube-system` Role is deliberately not copied: WAO already grants the CSV's namespaced
permissions cluster-wide (design brief D7), which covers reading
`kube-system/extension-apiserver-authentication`.
