# Known issues

Decisions that were made deliberately but leave something incomplete, and gaps that
are known but not yet worked on. Each entry has an owner decision to revisit, not a
bug to fix today. Add new entries at the end; keep numbers stable.

| # | Title | Status |
| --- | --- | --- |
| KI-1 | Console plugin enablement is manual and the ConsolePlugin registration outlives disable | Open, by decision |
| KI-2 | Platform Prometheus EndpointSlice discovery parity | Open |
| KI-3 | NHC upgrade will need APIServer TLS-profile RBAC | Open, upgrade-only |
| KI-4 | OpenShift platform audit of SNR, SBR, FAR, MDR and NMO | Open |
| KI-5 | Diagnostics (must-gather) not packaged | Open |
| KI-6 | `make test` discovers foreign Go sources under ignored `evidence/` | Open, local environment |
| KI-7 | Browser-level console validation is manual | Open |
| KI-8 | Intermittent MDR manager crashloop on the disposable cluster | Open |

## KI-1 Console plugin enablement is manual and the ConsolePlugin registration outlives disable

Decided 2026-10-09 (design spec
[2026-10-09-nhc-platform-integration-design.md](superpowers/specs/2026-10-09-nhc-platform-integration-design.md), P7, P8).

WAO deploys the console backend when NHC is enabled, but:

- It does not add `node-remediation-console-plugin` to
  `consoles.operator.openshift.io/cluster` `spec.plugins`. An administrator does that,
  preserving existing entries. Until then the backend runs and the UI does not load.
- The NHC manager creates the cluster-scoped `ConsolePlugin` at startup without an owner
  reference. When NHC is disabled, WAO removes the backend and the registration stays,
  pointing at a Service that no longer exists. If the plugin is still enabled, the
  console lists it as failed.
- WAO status does not show whether the plugin is enabled or whether a stale
  registration exists. NHC reports `Disabled`, not `DisableIncomplete`, in that state.

Alternatives considered: report the stale registration as a retained resource
(`DisableIncomplete`), or have WAO edit `Console/cluster` and delete the ConsolePlugin.
Both were declined for now: the first changes the meaning of `DisableIncomplete` for
every OpenShift disable, the second has WAO editing another operator's configuration and
deleting an object it did not create.

Revisit when: upstream NHC sets an owner reference on the ConsolePlugin, or when a
product decision assigns console enablement to WAO. Cleanup today:

```sh
oc --kubeconfig "$KUBECONFIG" patch consoles.operator.openshift.io cluster --type json \
  -p '[{"op":"remove","path":"/spec/plugins/<index of node-remediation-console-plugin>"}]'
oc --kubeconfig "$KUBECONFIG" delete consoleplugin node-remediation-console-plugin
```

The live harness performs enablement in `test/cluster/05-enable-nhc.sh` and removal in
`15-disable-nmo-nhc.sh`.

## KI-2 Platform Prometheus EndpointSlice discovery parity

The upstream OCP overlay grants the platform Prometheus ServiceAccount get/list/watch on
EndpointSlices in the operand namespace. WAO now renders that Role and RoleBinding for
NHC (P5). The inspected cluster's Prometheus uses `serviceDiscoveryRole: Endpoints`, so
the grant is not exercised there. Other operands' ServiceMonitors, if any, have not been
reviewed for the same need. Revisit when the platform Prometheus switches discovery to
EndpointSlices or when KI-4 is worked.

## KI-3 NHC upgrade will need APIServer TLS-profile RBAC

Newer NHC source (after v0.12.0) loads the cluster `APIServer` TLS security profile and
watches it, with matching RBAC. The pinned v0.12.0 image does not. Missing APIServer read
permission is therefore not a current failure. Revisit code and RBAC together on the next
NHC bump.

## KI-4 OpenShift platform audit of SNR, SBR, FAR, MDR and NMO

Only NHC's OpenShift packaging has been compared with its Kubernetes bundle. The other
five operands may have equivalent omissions (metrics TLS, console, monitoring RBAC).
Revisit before claiming complete OpenShift integration.

## KI-5 Diagnostics (must-gather) not packaged

The downstream OCP packaging adds a must-gather image and support metadata. No pinned
operand depends on it at runtime. Treat as a separate decision with its own image pin and
collection/redaction review. Do not copy product, subscription, FIPS or disconnected
claims into WAO.

## KI-6 `make test` discovers foreign Go sources under ignored `evidence/`

`controller-gen paths="./..."`, `go vet ./...` and `go list ./...` descend into
`evidence/`, which is git-ignored but holds Go sources from unrelated test suites with
dependencies outside WAO's module. Do not add those dependencies or delete someone else's
evidence. Run `make test` from an isolated copy of the tracked tree (for example
`git archive HEAD` into a temporary directory) and report where it ran. Revisit by
narrowing the Makefile paths or by keeping evidence outside the module root.

## KI-7 Browser-level console validation is manual

The cluster harness fetches `plugin-manifest.json` directly from the backend Service with
the namespace service CA, because the console's plugin proxy rejects non-browser sessions
(HTTP 401). That also verifies the backend's service-ca certificate. It does not load the UI
in a browser or exercise the list and details views. Do that manually after a run.

## KI-8 Intermittent MDR manager crashloop on the disposable cluster

Status: Open. Not caused by this branch: no MDR manifest or code changed, and the MDR
parity and disable cases passed. Observed in run 1 of 2026-10-10 (the MDR manager pod stayed
0/1 Running with 5 restarts in 5 minutes, and case 09 timed out) and in two of five earlier
runs on 2026-10-01. Case 09 now records `09-mdr-pods` and `09-events` on timeout. Revisit on
the next occurrence by inspecting those records.
