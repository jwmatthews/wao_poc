# Node Remediation console packaging: WAO context and upstream reference

This guide was adapted from the upstream Node Health Check (NHC) repository for
the Workload Availability Operator (WAO) POC. It describes WAO's current console
integration and the upstream packaging that would be relevant to adding a
console backend. Read WAO's [agent instructions](../AGENTS.md),
[design brief](design-brief.md), and [operand reference](operands.md) before
making changes.

Relative links refer to files in this WAO repository. NHC source links point to
commit `a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f`, the v0.12.0 source revision
recorded in the operand reference. Frontend links explicitly point to `main`
and describe that branch, not a frontend release selected by WAO. Recheck the
matching source and lockfiles when changing releases.

## Current WAO behavior

WAO consumes the published NHC bundle and manager image pinned by digest in
[release-set.yaml](../release-set.yaml). That selected bundle supplies no
console backend Deployment or Service. This differs from NHC's OpenShift and
OKD packaging variants described below.

| WAO source | Console integration today |
| --- | --- |
| [Release set](../release-set.yaml) | Pins NHC v0.12.0 and its manager image; contains no console plugin image. |
| [Extracted NHC manifests](../internal/operands/manifests/nhc/) | Include the manager, admission, metrics, and RBAC resources; contain no console backend workload. |
| [NHC component definition](../internal/components/nhc.go) | Declares only the NHC manager Deployment and manager image binding. |
| [Operand extractor](../hack/extract-operand-manifests.py) | Generates operand resources from the selected published bundle. |
| [NHC install check](../test/cluster/05-enable-nhc.sh) | Records whether NHC created a `ConsolePlugin`; does not verify a working console UI. |

All WAO components start Disabled. When NHC is enabled on OpenShift, its
unchanged manager initializes the `ConsolePlugin` registration described below.
The registration can therefore exist while its backend Service and Deployment
are absent. Enabling that name in the console configuration alone does not
supply the missing backend.

Adding the backend to WAO would require an explicit packaging and lifecycle
change, including a digest-pinned frontend image, supporting operand resources,
and readiness and disable behavior. Follow WAO's constraints: consume upstream
images without rebuilding the component operators, keep all components Disabled
by default, and do not add a public component-image override. The upstream NHC
Makefile variables and overlays below are reference material; WAO's
[Makefile](../Makefile) does not define those console packaging targets.

## Upstream components and ownership

The Node Remediation console is an OpenShift dynamic plugin that supplies NHC
list, create, edit, and details pages. Its frontend source lives in the separate
[node-remediation-console repository](https://github.com/medik8s/node-remediation-console).
The upstream
[NHC repository](https://github.com/medik8s/node-healthcheck-operator/tree/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f)
selects the frontend image and packages its Kubernetes resources in the
OpenShift and OKD bundles. The NHC manager registers the plugin with OpenShift.

| Artifact | Contents and responsibility |
| --- | --- |
| NHC operator image | Go controller and startup initialization, including creation of the `ConsolePlugin` resource. |
| Console plugin image | Compiled frontend assets served by nginx in its own Deployment. Built in the frontend repository. |
| NHC OLM bundle image | Installation manifests, CRDs, permissions, and a ClusterServiceVersion (CSV). The OpenShift variants reference both runtime images. |
| Optional catalog image | Operator package, channel, and bundle metadata used to distribute releases through OLM. |

The bundle contains manifests and image references. It does not embed the
frontend image or rebuild the frontend. The NHC operator and plugin server run
as separate workloads.

## Upstream frontend build and publication

The frontend repository's
[Dockerfile](https://github.com/medik8s/node-remediation-console/blob/main/Dockerfile)
uses a multi-stage build:

1. A Node.js builder runs `npm ci` and `npm run build`.
2. Webpack and the OpenShift dynamic-plugin SDK produce the plugin manifest,
   JavaScript bundles, and other assets in `dist/`.
3. The final nginx image receives those assets and the nginx configuration.
4. nginx serves HTTPS on port `9443`, reading its certificate and key from
   `/var/serving-cert/tls.crt` and `/var/serving-cert/tls.key`.

The frontend's
[Webpack configuration](https://github.com/medik8s/node-remediation-console/blob/main/webpack.config.ts)
and [package.json](https://github.com/medik8s/node-remediation-console/blob/main/package.json)
define the exposed modules and build behavior. Its
[nginx configuration](https://github.com/medik8s/node-remediation-console/blob/main/default.conf)
disables caching for `plugin-entry.js` and `plugin-manifest.json`.

The frontend's
[publishing workflow](https://github.com/medik8s/node-remediation-console/blob/main/.github/workflows/post-submit.yaml)
publishes `quay.io/medik8s/node-remediation-console:latest` from main and versioned
images from release tags. These links describe main; inspect the matching
frontend tag and lockfile when investigating a released image. Do not assume
main's dependency versions describe the image selected by NHC.

## Upstream NHC image selection and OLM packaging

For release builds, the upstream [NHC Makefile](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/Makefile) selects the console image as follows:

```make
CONSOLE_PLUGIN_IMAGE_BASE ?= quay.io/medik8s/node-remediation-console
CONSOLE_PLUGIN_TAG ?= v$(VERSION)
CONSOLE_PLUGIN_IMAGE ?= $(CONSOLE_PLUGIN_IMAGE_BASE):$(CONSOLE_PLUGIN_TAG)
```

NHC's default development version uses `latest` instead of `v$(VERSION)`.
The Makefile documents matching NHC and console release tags. In an upstream
NHC development checkout, `CONSOLE_PLUGIN_IMAGE` can select a separately
published frontend image. Changing NHC's `IMAGE_REGISTRY` or `IMG` alone does
not redirect the console image: its registry and tag have their own variables.

Bundle generation sets the `console-plugin` image through Kustomize, then uses
Operator SDK to generate the CSV and other bundle manifests. The selected
overlay determines whether the plugin workload is included:

| Target | Overlay | Plugin workload included? |
| --- | --- | --- |
| `bundle-ocp` | [config/manifests/ocp](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/manifests/ocp/kustomization.yaml) | Yes |
| `bundle-okd` | [config/manifests/okd](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/manifests/okd/kustomization.yaml) | Yes |
| `bundle-k8s` | [config/manifests/k8s](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/manifests/k8s/kustomization.yaml) | No |

`bundle-ocp` and `bundle-okd` also add this CSV annotation:

```yaml
console.openshift.io/plugins: '["node-remediation-console-plugin"]'
```

The [bundle Dockerfile](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/bundle.Dockerfile) copies the generated manifests,
metadata, and scorecard configuration into a `FROM scratch` image. Catalog
generation uses `opm` to package bundle and channel metadata.

NHC's checked-in bundle is maintained as the Kubernetes variant by
`bundle-reset`. Its lack of a console Deployment does not mean NHC's OpenShift
bundle lacks one. In an NHC checkout, change source manifests and regenerate
the appropriate variant. In WAO, the published bundle selected by
`release-set.yaml` and the resources extracted from it determine what can be
installed; the presence of an overlay in NHC's source does not add it to WAO.

## Upstream backend resources and TLS

The [console Kustomization](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/optional/console-plugin/kustomization.yaml)
includes the Deployment, Service, ServiceAccount, Role, and RoleBinding. In a
standalone NHC OpenShift or OKD installation, OLM installs the workload and
supporting resources from that bundle. WAO's selected bundle omits this backend.

| Resource or setting | Upstream contract at the linked NHC revision |
| --- | --- |
| Plugin identity | `node-remediation-console-plugin` |
| Deployment and Service name after Kustomize prefixing | `node-healthcheck-node-remediation-console-plugin` |
| Backend namespace | NHC's installation namespace, supplied during operator initialization |
| Service type and port | `ClusterIP`, HTTPS `9443` |
| Backend base path | `/` |
| Serving certificate Secret | `nrc-plugin-cert` |
| Certificate mount | `/var/serving-cert` |

The [Service annotation](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/optional/console-plugin/service.yaml)
`service.beta.openshift.io/serving-cert-secret-name` asks OpenShift to supply the
serving certificate Secret. The
[Deployment](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/optional/console-plugin/deployment.yaml)
mounts it read-only and runs one replica as non-root. Its health probes check
TCP port `9443`. At this pinned revision, the Deployment does not set
`readOnlyRootFilesystem` or provide separate nginx runtime volumes; do not
assume a newer frontend image has the same filesystem requirements.

The [common Kustomize component](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/patches/common/kustomization.yaml)
adds the `node-healthcheck-` prefix. Preserve agreement between rendered names
and the constants in [plugin.go](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/internal/controller/console/plugin.go).
Source YAML namespace placeholders are not a reliable way to discover the
namespace of an OLM installation.

The small [console Role](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/optional/console-plugin/role.yaml) intentionally
contains a no-op permission so the generated CSV has a permissions entry for
the plugin ServiceAccount. OLM uses these entries to create ServiceAccounts.
Do not remove it merely because nginx does not use that ConfigMap permission.

## Registration, enablement, and loading

These are separate stages:

1. **Deploy the server.** NHC's OpenShift and OKD bundles supply the nginx
   Deployment, Service, and supporting resources. WAO currently lacks this stage.
2. **Register the backend.** NHC's
   [initializer](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/internal/controller/initializer/init.go) calls
   `console.CreateOrUpdatePlugin`. On OpenShift, it creates or updates the
   cluster-scoped `ConsolePlugin` with the Service name, installation namespace,
   port `9443`, and base path `/`. On plain Kubernetes it skips this step.
3. **Enable the plugin.** The name must appear in `spec.plugins` on
   `consoles.operator.openshift.io/cluster`. The CSV annotation allows the
   OpenShift operator installation screen to offer plugin enablement for those
   upstream bundle variants. NHC's initialization code does not modify that
   enabled-plugin list.
4. **Load the frontend.** The OpenShift console backend proxies asset requests
   to the plugin Service. The browser loads the manifest and JavaScript into
   the existing console session; the plugin does not need its own public Route.

```text
Browser -> OpenShift console backend -> plugin Service:9443 -> nginx pod
```

See the [OpenShift dynamic-plugin design](https://github.com/openshift/enhancements/blob/master/enhancements/console/dynamic-plugins.md)
and [enablement example for OpenShift 4.22](https://github.com/openshift/console/blob/release-4.22/dynamic-demo-plugin/README.md#enabling-the-plugin).
Preserve existing entries when changing `spec.plugins`.

The source [consoleplugin.yaml](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/optional/console-plugin/consoleplugin.yaml)
is commented out of the Kustomization; the active registration is constructed
in Go. Editing only that YAML will not change startup registration. This is
startup initialization, not a dedicated continuous reconciliation loop. The
code also has an unresolved owner-reference TODO, so do not assume uninstalling
NHC automatically garbage-collects the cluster-scoped `ConsolePlugin`.

## Development and verification in WAO

Use WAO's [README](../README.md) and
[implementation plan](implementation-plan.md) for work in this repository.
The NHC `dev-*` workflow and console overlays are not WAO workflows. Even in
an upstream NHC checkout, plain `make deploy` defaults to
[NHC's config/default](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/config/default/kustomization.yaml),
which excludes the plugin resources. Selecting a console image alone does
not include its Deployment.

After confirming the disposable OpenShift cluster to use in the current
session, these read-only checks distinguish registration, backend deployment,
certificate availability, and enablement. Each command passes `KUBECONFIG`
explicitly and writes raw output under the git-ignored `evidence/` directory,
as required by WAO's agent instructions. The Secret check records only its
name, never its values. Missing backend resources are expected with WAO's
current packaging.

```bash
(
set -euo pipefail
: "${KUBECONFIG:?set KUBECONFIG to the confirmed disposable cluster}"
RUN_DIR="evidence/$(date -u +%F)-console-plugin"
mkdir -p "$RUN_DIR"
exec 2>"$RUN_DIR/checks.stderr"

oc --kubeconfig "$KUBECONFIG" get consoleplugin \
  node-remediation-console-plugin -o yaml >"$RUN_DIR/consoleplugin.yaml"

NHC_NAMESPACE=$(oc --kubeconfig "$KUBECONFIG" \
  get consoleplugin node-remediation-console-plugin \
  -o jsonpath='{.spec.backend.service.namespace}')
oc --kubeconfig "$KUBECONFIG" -n "$NHC_NAMESPACE" get deployment,service \
  -l app.kubernetes.io/component=node-remediation-console-plugin \
  -o yaml >"$RUN_DIR/backend.yaml"
oc --kubeconfig "$KUBECONFIG" -n "$NHC_NAMESPACE" \
  get secret nrc-plugin-cert --ignore-not-found -o name \
  >"$RUN_DIR/serving-cert-secret-name.txt"

oc --kubeconfig "$KUBECONFIG" get consoles.operator.openshift.io cluster \
  -o jsonpath='{.spec.plugins}{"\n"}' >"$RUN_DIR/enabled-plugins.txt"
)
```

The [console e2e test](https://github.com/medik8s/node-healthcheck-operator/blob/a49ec14c47c5c1f0e5b81c68bf2880ff17ec4a5f/e2e/nhc_console_e2e_test.go) is OpenShift-only. It finds
the registration and Service, fetches `/plugin-manifest.json` from inside the
cluster with `curl -k`, and checks for the plugin name. It does not verify TLS
trust, console enablement, browser loading, or UI interactions. A passing TCP
probe or manifest fetch is therefore only part of end-to-end verification.

For future changes, use the sources owned by the relevant repository:

- Frontend pages, assets, or nginx behavior: the separate frontend repository.
- Upstream workload, certificate mounts, or Service settings: NHC's
  `config/optional/console-plugin/`.
- Upstream registration name, backend namespace, or port: NHC's
  `internal/controller/console/plugin.go`, keeping its manifests consistent.
- Upstream image selection, bundle variants, or CSV metadata: NHC's `Makefile`
  and `config/manifests/`.
- WAO packaging: this repository's `release-set.yaml`, operand extractor,
  component definitions, image bindings, and bundle generation. Regenerate
  extracted manifests through the documented workflow.
- Enabled-plugin list: the selected cluster's OpenShift console operator
  configuration, preserving other enabled plugins.

Before committing WAO changes, run `make test` and `make test-offline` as
required by [AGENTS.md](../AGENTS.md). A future WAO console integration also
needs verification of its rendered backend resources and image digest, plus
TLS trust, console enablement, browser loading, and UI behavior on the
confirmed disposable cluster. NHC's OpenShift or OKD bundle checks apply when
working on upstream packaging; they do not verify WAO's extracted operands.
