# WAO configuration update conflicts investigation

Date: 2026-10-15. All timestamps below are UTC.

Status: investigation findings with local diagnostic logging added; no
concurrency fix implemented or deployed.

## Summary

WAO logged seven reconciliation errors while updating
`WorkloadAvailabilityConfig/cluster`. Each error says the object was modified
and the update must be applied to its latest version.

The leading hypothesis is that a reconciliation reads an older configuration
from controller-runtime's cache, then submits a status update with a stale
`resourceVersion`. A successful write from a previous reconciliation can cause
this even with a single controller worker. A configuration edit during a
reconciliation can also cause the same error.

The code and observed timing support this explanation. The existing logs do not
contain the object versions or successful writes needed to establish the exact
sequence behind each of the seven failures.

## Evidence observed

The investigation used read-only logs, deployment and pod status, configuration
status and managed fields, and local source inspection. This note omits cluster
addresses, kubeconfig paths, generated pod identifiers, and object UIDs.

The running WAO build identified itself as commit
`9e705186bd21963e1b090c600828776a781732c9`, using controller-runtime `v0.21.0`.
The relevant controller and manager source files in the local checkout matched
that deployed commit when inspected.

WAO acquired its leader lease at `19:47:02` and started one reconciliation
worker. The deployment had one replica, leader election was enabled, and the
WAO pod was ready with zero restarts at the initial inspection.

The seven errors were:

| Time | Observation |
| --- | --- |
| 20:07:07 | Configuration update rejected because the object was modified |
| 20:07:11 | Same error |
| 20:07:12 | Same error |
| 20:07:17 | Same error |
| 20:07:19 | Same error |
| 20:08:39 | Same error |
| 21:05:58 | Same error |

The managed fields showed a `kubectl-patch` update to all six component states
at `20:07:03`. All six were `Enabled` when inspected. The first conflict occurred
approximately four seconds after that configuration change, during operand
installation activity.

The recorded status field manager was `manager`. No distinct competing status
manager was visible. Managed fields are not a complete audit history, and the
generic manager name does not uniquely identify a process, so this does not
prove there was only one writer throughout the period.

The later log inspection still showed those same seven conflicts, with the last
one at `21:05:58`.

## What the error means

Kubernetes uses `metadata.resourceVersion` to detect updates based on an older
object. An update supplies the version the client read. If the server already
holds a newer version, it rejects the update with HTTP `409 Conflict` rather
than overwrite newer data. A status update is subject to this version check
even though it writes through the `/status` subresource.

This is different from a component installation failure or WAO refusing to adopt
an unmanaged operand object. The error names the WAO configuration object itself.

## Relevant WAO behavior

The implementation follows this sequence:

1. `Reconcile` reads the configuration once through `r.Get`.
2. It processes all six components, applying enabled operands and inspecting
   their readiness.
3. It builds the aggregate status and calls `r.Status().Update(ctx, wac)` using
   the object obtained at the start.
4. If that update fails, it returns the error. Controller-runtime logs the
   error and queues another reconciliation with backoff.

The reconciler uses `mgr.GetClient()`. For this structured configuration object,
the default client reads from the local informer cache and writes directly to
the API server. A successful write does not synchronously refresh the cache.

The controller watches the configuration and operand Deployments, Services,
webhook configurations, and DaemonSets. Operand changes can queue another
reconciliation while the current one is still running. There is no predicate
on the configuration watch excluding status-only updates, so changed status can
also trigger another pass.

There is no explicit semantic equality check before the status update and no
targeted retry around that write. However, `summarize` preserves unchanged
condition transition times. An identical update does not necessarily persist a
new object version. These findings do **not** establish an endless status-update
loop or continuous version churn.

Source references:

- [Controller](../../internal/controller/workloadavailabilityconfig_controller.go):
  `Reconcile`, `ensureEnabled`, and `SetupWithManager`.
- [Manager setup](../../cmd/main.go): manager cache options and `mgr.GetClient()`.
- [Status aggregation](../../internal/controller/status.go): `summarize` and
  preservation of condition transition times.
- [Bootstrap](../../internal/controller/bootstrap.go): creates the default
  configuration if absent; does not modify an existing configuration.

## A plausible sequence with one worker

The versions A and B below are illustrative labels, not captured object versions.

1. A reconciliation successfully writes status. The server now has version B.
2. An operand event has already queued another reconciliation.
3. The next reconciliation starts before the configuration cache observes B,
   and reads version A.
4. It applies operand resources and computes status using that object. Even if
   the cache catches up during this work, the local object retains version A.
5. It submits the status update with A. The server has B and rejects the update.
6. Controller-runtime retries. A later reconciliation can read the newer version
   and successfully publish status.

This does not require two reconciliations to run simultaneously. It requires
the next pass to read a cache that has not caught up with an earlier write.

The burst immediately after enabling all components is consistent with a period
of frequent operand events and status changes. Processing every operand between
the configuration read and status write also leaves time for an external edit
to invalidate the version. The duration and version sequence were not measured.

## Confidence and limits

**Confirmed:** the API rejected seven updates to the WAO configuration; WAO uses
a cached read followed by an unconditional status-update attempt; errors cause a
full reconciliation retry; there was one deployed WAO replica and one worker at
inspection.

**Likely:** at least some conflicts came from WAO reading behind its own earlier
status writes during a busy reconciliation period.

**Not established:** which successful write preceded each failure, the cache lag
at those moments, whether an external writer contributed, or whether the later
isolated error had the same trigger as the initial burst. Existing logs do not
identify the failing write operation explicitly, although the post-bootstrap
code path strongly points to the status update.

## Impact and related observations

A rejected status update can temporarily leave reported readiness behind the
actual operand state. It also causes another full pass over the six components,
adding API work and error-log noise. Operand changes successfully applied before
the rejected status write are not rolled back.

WAO subsequently published successful status. An observed status snapshot had
`Available=True` and `Progressing=False`, with both conditions transitioning at
`23:11:52`. A later snapshot showed `Available=False` and `Progressing=True`,
transitioning at `23:12:17`, because machine-deletion-remediation had zero ready
replicas. Both snapshots had `Degraded=False` and observed configuration
generation 2. These are historical observations, not a claim about current
cluster health.

Machine-deletion-remediation separately had 46 recorded restarts at inspection.
Its previous container logs showed API timeouts during leader election, and its
last recorded termination was `Error`, exit code 137. Those observations do not
establish the termination cause or prove a causal connection to the WAO update
conflicts. Keep that investigation separate while considering whether API
latency could amplify reconciliation or cache delays.

## Proposed next steps

### 1. Make the next conflict attributable

Diagnostic logging has been added locally in
[config_logging.go](../../internal/controller/config_logging.go) and the
reconciler. It becomes available in the cluster only after a WAO build containing
these changes is deployed. No deployment was performed as part of this work.

| Message | Level | Useful fields |
| --- | --- | --- |
| `read WorkloadAvailabilityConfig` | Debug | `operation=config.get`, `resourceVersion`, `generation`, `observedGeneration`, `deleting` |
| `writing WorkloadAvailabilityConfig` | Debug | `operation`, `attemptedResourceVersion`, `generation`, `observedGeneration`, `reconcileDuration`; status attempts also include `statusChanged` |
| `wrote WorkloadAvailabilityConfig` | Debug | Attempt metadata plus `returnedResourceVersion`, `writeDuration`, `reconcileDuration` |
| `WorkloadAvailabilityConfig write failed` | Info | Attempt metadata plus `error`, `conflict`, `writeDuration`, `reconcileDuration`; the original returned error is still logged at Error by controller-runtime |
| `WorkloadAvailabilityConfig conflict comparison` | Info | Attempt metadata plus `liveReadSucceeded`; successful reads include `liveResourceVersion`, `liveGeneration`, `liveObservedGeneration`, `liveDeleting`, `sameUID`; failed reads include `liveReadError` |
| `WorkloadAvailabilityConfig status changed` | Info | Published version and generation, component phases, and aggregate condition statuses; emitted after a successful write when computed status differs from the initial snapshot |

All messages retain controller-runtime's existing reconciliation context,
including `reconcileID`. Write operations distinguish `status.update`,
`finalizer.add`, and `finalizer.remove`. The conflict comparison uses the
manager's direct API reader with a two-second timeout, not the informer cache.
It never retries the write or replaces the original error, even if the
diagnostic read fails. Non-conflict failures do not trigger a diagnostic read.

The existing development logger enables debug output by default. If logging
has been overridden, use the existing `--zap-log-level=debug` controller argument
when gathering the read/write sequence. Treat resource versions as opaque
strings: correlate recorded values rather than sorting or subtracting them.

Compare a successful write's returned version with subsequent cached reads to
look for reads of the earlier attempted version. A fresh read after a failure
is a later observation, not an atomic snapshot at the instant of failure. A
different generation indicates a configuration change; an unchanged generation
with a different version can reflect status or metadata changes. Neither the
generic managed-field manager name nor these logs alone identifies an external
writer conclusively.

The logs contain selected metadata and bounded phase/condition summaries, not
credentials, Secret values, full configuration payloads, or component messages.
Existing reconciliation retries and unconditional status-write attempts remain
unchanged. There is no new custom conflict metric in this logging change.

### 2. Reproduce the timing locally

Use a controlled client or informer setup to simulate a successful status write
followed by an older cached read. Verify the current conflict-and-requeue
behavior, then verify the selected improvement. Also cover a spec change during
reconciliation and unchanged status. This can be done without a live cluster;
a client that always provides immediate read-after-write consistency will miss
the suspected failure mode.

### 3. Improve status publication

Evaluate a small, dedicated status-publication operation that:

- Skips writes when the desired status is semantically unchanged.
- Uses a fresh API read for conflict retries, with a bounded retry policy.
- Checks object identity, generation, and deletion state before publishing the
  computed status; restarts reconciliation if that computation is obsolete.
- Handles expected conflicts without repeatedly reapplying every operand solely
  to retry status, while retaining visibility into persistent failures.

Do not simply copy a newer resource version onto an older computation or retry
the same stale object. Do not assume replacing Update with Patch alone preserves
the intended concurrency guarantees. Select the write strategy and its tests
together.

Filtering configuration status-only events could reduce extra reconciliations,
but should be considered separately. Preserve required deletion/finalizer
handling, operand readiness watches, and periodic requeues.

### 4. Validate before integration

Run the focused regression checks and the repository's `make test` and
`make test-offline` checks before any commit. Any later live-cluster validation
requires confirmation of an authorized disposable cluster in that session and
explicit kubeconfig selection. It must not create real remediation policies,
requests, or other node-affecting test resources.

Keep any fix within WAO: preserve upstream operand images, Disabled defaults,
webhook failure policies, and refusal to adopt foreign objects. Review sanitized
cluster results before committing them. Any proposed GitHub write requires
review and explicit approval of that specific action.

## References

- [Kubernetes API concepts: updates to existing resources](https://kubernetes.io/docs/reference/using-api/api-concepts/#updates-to-existing-resources)
- [controller-runtime v0.21.0: clients and caches](https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.21.0#hdr-Clients_and_Caches)
- [controller-runtime v0.21.0: reconciliation contract](https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.21.0/pkg/reconcile#Reconciler)
