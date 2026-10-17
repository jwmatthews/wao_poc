# NHC metrics on OpenShift

The pinned NHC manager serves metrics using mutual TLS when its metrics serving
certificate is present at startup. WAO supplies the OpenShift packaging that the
upstream bundle omits. This adds one generated ConfigMap: NHC has **13** generated
manifests and the six operands have **91** in total. Every component still defaults
to `Disabled`; the all-Disabled Kind smoke suite does not exercise this contract.

| Field or object | Maintained by |
| --- | --- |
| `node-healthcheck-ca-bundle` metadata, injection annotation and WAO ownership | WAO |
| ConfigMap `data.service-ca.crt` | OpenShift service-CA |
| Metrics Service `app.kubernetes.io/instance=metrics` label and serving-certificate annotation for `node-healthcheck-tls` | WAO |
| `node-healthcheck-tls` serving certificate Secret | OpenShift service-CA; follows its Service ownership |
| Required metrics certificate volume and manager mount | WAO |
| `node-healthcheck-controller-manager-metrics-monitor` ServiceMonitor | Upstream NHC, owned by its Deployment |
| Platform scrape class, client certificate and Prometheus configuration | OpenShift monitoring |

WAO's ConfigMap apply payload omits both `data` and `binaryData`. Reconciliation
must preserve service-CA's injected contents and field ownership. WAO watches its
owned ConfigMaps so deletion triggers recreation; service-CA then reinjects the
bundle. WAO reports foreign-object conflicts and never adopts a preexisting CA
ConfigMap. It does not render a metrics Secret or a ServiceMonitor.

The metrics `tls-config` volume requires Secret `node-healthcheck-tls`, with
`optional: false` and explicit `tls.crt` and `tls.key` items. The manager mounts
its directory read-only at `/etc/tls/private`, without `subPath`, separately from
the webhook certificate. These required keys prevent startup before service-CA
issues the certificate. The pinned manager chooses mTLS once during startup; a
manager that already selected bearer authentication needs a normal rollout after
the required certificate mount is introduced. The upstream client-CA controller
reads `kube-system/extension-apiserver-authentication` and its `client-ca-file`
key. Certificate refresh uses service-CA and upstream certificate watchers; this
repair does not force certificate rotation.

## Read-only verification

Run against an already enabled NHC on the disposable OpenShift cluster confirmed
for the current session. Supply a readable kubeconfig explicitly:

```sh
export WAO_TEST_KUBECONFIG=/path/to/authorized-disposable-kubeconfig
export WAO_OPERAND_NAMESPACE=openshift-workload-availability
python3 test/openshift/check-nhc-metrics.py \
  --kubeconfig "$WAO_TEST_KUBECONFIG" \
  --namespace "$WAO_OPERAND_NAMESPACE" --timeout 300
```

Exit status is `0` for verified health, `1` for an unhealthy or incomplete check,
and `2` for invalid arguments. `--timeout 0` performs one scan without polling;
its complete scan is bounded to 90 seconds. Positive timeouts bound collection
and polling together, with a five-second polling interval. Every `oc` call has
an explicit kubeconfig, a request timeout and a process timeout. No command can
run indefinitely. Missing permissions, unavailable logs, truncated logs,
malformed responses and unsuccessful queries fail verification.

The checker uses resource GETs, startup/operator log reads, effective
`oc auth can-i` checks through service-account impersonation, and GET-only curl
queries inside existing `prometheus-k8s` containers. The caller therefore needs
read, log, pod-exec and impersonation permissions. It does not read Secrets,
extract tokens, install tools, create policies or modify cluster resources.
Authorization reviews from `oc auth can-i` do not persist resources.

A successful check requires:

- A populated injected CA, the expected metrics Service metadata and pod selector,
  and the upstream-owned monitor's CA reference, HTTPS port, verified server name
  and `tls-client-certificate-auth` scrape class.
- Required certificate keys and directory mount, all desired NHC replicas ready,
  and positive `Configuring secure metrics with mTLS` startup evidence from every
  ready manager, with no bearer-authentication fallback.
- Namespace monitoring selection, the platform mTLS scrape class, NHC's effective
  ConfigMap get/list/watch permissions in `kube-system`, and Prometheus discovery
  get/list/watch permissions for Services, Pods and the configured Endpoints or
  EndpointSlice discovery role (monitor override, then Prometheus setting,
  defaulting to Endpoints).
- Exactly one healthy target per ready NHC manager in each available platform
  Prometheus replica, selected by the precise scrape pool
  `serviceMonitor/<operand-namespace>/node-healthcheck-controller-manager-metrics-monitor/0`.
  Each target must have an empty `lastError`, and matching `up` samples must equal
  `1` for all expected pods. Historical series for old pods within Prometheus's
  query lookback window are ignored; every current ready pod still requires
  exactly one successful sample. An unavailable Prometheus replica or a failed query
  fails the check even when its peer is healthy.
- Positive target/sample evidence and no new monitor-specific rejection events
  or Prometheus-operator log entries since the check began. Historical Warning
  events alone do not fail a repaired installation.

Stdout is sanitized JSON containing `healthy`, named `failures`, condition
booleans, counts, a start timestamp and a per-Prometheus-replica result indexed by
number. It contains no certificate contents, namespace value, kubeconfig path,
pod identities, addresses or raw command errors. `aggregate_rejection_alert`
reports firing/pending counts separately; an alert caused by other monitors does
not invalidate successful NHC checks or establish an NHC rejection. Its counts
use the maximum observed across the queried replicas, avoiding double counting.
A missing query is a verification failure, even if the displayed alert counts
are zero. Failed collection may leave some condition fields unobserved/false;
read the named failures before interpreting counts.

`evaluate(snapshot)` is an I/O-free fixture interface. Its transient pod IDs are
used only to compare ready managers, scrape targets and samples; they are removed
from the emitted summary. Offline tests use a strict fake `oc` that rejects
mutations, Secret reads and exec commands other than the expected curl GETs:

```sh
make test-offline
```

## Authorized lifecycle runbook

These are future, explicitly authorized cluster mutations, separate from the
read-only checker. Confirm a disposable OpenShift cluster with classic OLM,
service-CA and platform monitoring in the current session before execution.
Keep raw cluster output outside the repository; store only reviewed sanitized
summaries. Never create a real `NodeHealthCheck`, remediation request,
`StorageBasedRemediationConfig` or `NodeMaintenance` during these checks. Abort
lifecycle work if existing policies, requests, native configs, maintenance
objects or node agents make disabling operands unsafe.

1. Install or upgrade the candidate WAO through the separately reviewed classic
   OLM procedure. Begin with a fresh all-Disabled configuration. Confirm no NHC
   Deployment, metrics Service, injected CA ConfigMap, metrics serving Secret or
   ServiceMonitor was created by that install. Do not infer a default-state pass
   from the enabled-operand checker, which deliberately fails without NHC.
2. Enable only NHC after checking all other components remain Disabled:

   ```sh
   oc --kubeconfig "$WAO_TEST_KUBECONFIG" --request-timeout=15s \
     patch workloadavailabilityconfig cluster --type=merge \
     -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"}}}}'
   python3 test/openshift/check-nhc-metrics.py \
     --kubeconfig "$WAO_TEST_KUBECONFIG" \
     --namespace "$WAO_OPERAND_NAMESPACE" --timeout 300
   ```

   Require two ready managers, two healthy NHC targets and two successful `up`
   samples per platform Prometheus replica. If NHC was the aggregate rejected
   resources alert's only cause, allow its evaluation window to elapse and
   require the aggregate firing count to return to zero. Otherwise investigate
   other monitors separately.
3. Capture sanitized CA-data and Deployment-template hashes, Deployment
   generation, ownership checks and target counts. Repeat no-op reconciliations,
   then restart the WAO manager once using the actual reviewed Deployment name:

   ```sh
   oc --kubeconfig "$WAO_TEST_KUBECONFIG" --request-timeout=15s \
     rollout restart deployment "$WAO_MANAGER_DEPLOYMENT" -n "$WAO_OPERATOR_NAMESPACE"
   oc --kubeconfig "$WAO_TEST_KUBECONFIG" --request-timeout=15s \
     rollout status deployment "$WAO_MANAGER_DEPLOYMENT" -n "$WAO_OPERATOR_NAMESPACE" --timeout=120s
   python3 test/openshift/check-nhc-metrics.py \
     --kubeconfig "$WAO_TEST_KUBECONFIG" \
     --namespace "$WAO_OPERAND_NAMESPACE" --timeout 300
   ```

   Require unchanged injected CA hash and ownership, and unchanged NHC
   Deployment generation/template. Introducing the metrics volume initially
   causes one normal rollout; repeated reconciliation must not cause more.
4. Verify the CA ConfigMap is WAO-owned, then test deletion recovery without
   changing the WAC:

   ```sh
   oc --kubeconfig "$WAO_TEST_KUBECONFIG" --request-timeout=15s \
     delete configmap node-healthcheck-ca-bundle -n "$WAO_OPERAND_NAMESPACE"
   python3 test/openshift/check-nhc-metrics.py \
     --kubeconfig "$WAO_TEST_KUBECONFIG" \
     --namespace "$WAO_OPERAND_NAMESPACE" --timeout 300
   ```

   Require recreation, CA reinjection and healthy scraping after the transient
   reload window while NHC remains Available. Never delete a foreign ConfigMap
   or force rotation by deleting serving Secrets.
5. Disable NHC and check removal of WAO's CA ConfigMap and manager resources,
   Deployment-owned ServiceMonitor garbage collection and service-CA's
   Service-owned serving Secret cleanup. WAO does not directly own that Secret:

   ```sh
   oc --kubeconfig "$WAO_TEST_KUBECONFIG" --request-timeout=15s \
     patch workloadavailabilityconfig cluster --type=merge \
     -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Disabled"}}}}'
   ```

   Re-enable with step 2 and require fresh healthy scrapes. In a separate clean
   default/finalization scenario, delete the test WAC while WAO and its RBAC are
   still installed, then verify its managed resources are removed:

   ```sh
   oc --kubeconfig "$WAO_TEST_KUBECONFIG" --request-timeout=15s \
     delete workloadavailabilityconfig cluster
   ```

   Preserve any foreign conflicting object. Review only sanitized booleans,
   counts, hashes and timestamps for `REPORT.md` and `results.json`; commit such
   summaries only after review and an explicit request to commit.
