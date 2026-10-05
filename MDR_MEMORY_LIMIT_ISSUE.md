# MDR v0.7.0 manager cannot start on a cold page cache: 30Mi memory limit is smaller than its binary

> Prepared for a possible upstream issue against
> [medik8s/machine-deletion-remediation](https://github.com/medik8s/machine-deletion-remediation).
> Nothing has been filed. Node names, IP addresses, cluster names and API URLs are
> removed on purpose. The last section is a draft issue you can paste.

## Summary

The Machine Deletion Remediation (MDR) operator's manager container has a memory
limit of `30Mi`. Its `/manager` binary is about 53 MB. On cgroup v2, page cache
pages for the binary are charged to the container's memory cgroup when the
container is the first to read them. So the outcome depends on whether the binary
is already in the node's page cache:

- **Warm cache** (pages already cached and charged to an earlier, now-dead cgroup):
  the manager starts in about 13 s and uses about 12–14 MB.
- **Cold cache** (the container reads the binary itself): about 24 MB of binary
  pages plus about 6 MB of anonymous memory fill the 30Mi limit before the program
  finishes loading. The kernel keeps evicting and re-reading the binary's pages,
  about 1.75–1.88 million file refaults per container lifetime. The process never
  reaches its first log line, never opens the health port, and is killed by the
  liveness probe every 60 s. This repeats forever (CrashLoop).

Raising only the memory limit fixes it: at `40Mi` it starts but still thrashes; at
`64Mi` it starts cleanly.

A cold page cache is common in practice: the first start on a node after a reboot
or upgrade, a node that just pulled the image, or a node whose cache was reclaimed
under memory pressure. In our tests it happened without any manual cache eviction
in 2 of 4 automated install runs.

## Affected version and current upstream state

| Item | Value |
| --- | --- |
| MDR release | v0.7.0 (latest release when checked on 2026-10-02) |
| Operator image | `quay.io/medik8s/machine-deletion-remediation-operator@sha256:0f69367097625d7824d9b5b69de64103e19b612c9833b0b786bb32c9b7efe84d` |
| Bundle image | `quay.io/medik8s/machine-deletion-remediation-operator-bundle@sha256:b95a8e63056912168383bacdc13fd20a1df62d1ac9808978b127cf14871cf393` |
| Build (from the manager's log) | Go go1.25.9, linux/amd64, git commit `39beef663ae7db0edd7d472362bbe445729e548d`, built 2026-06-17 |
| Binary size | `/manager` 53 MB (13,558 pages, from `fincore`) |
| Resources in the CSV and in `config/manager/manager.yaml` on `main` | limits `cpu: 100m`, `memory: 30Mi`; requests `cpu: 100m`, `memory: 20Mi` |
| Existing upstream issue or PR | None found (GitHub search of issues and PRs for "memory" on 2026-10-02 returned only dependency bumps) |

## Test environment

- OpenShift 4.22.1, 3 nodes (compact, `HighlyAvailable` control plane), amd64, on AWS.
- RHCOS 9.8 (`5.14.0-687.13.1.el9_8.x86_64`), CRI-O 1.35.4, cgroup v2.
- Nodes lightly loaded (14–20% CPU, about 65% memory).
- MDR installed standalone with OLM, AllNamespaces (the only install mode the CSV supports).

## Symptoms

- Pod never becomes Ready; `restartCount` climbs about once a minute.
- `oc logs` and `oc logs --previous` are **empty**. A healthy start prints the Go
  version banner first, before any API call, so the process never gets that far.
- The previous container's state is `terminated`, `reason: Error`, `exitCode: 2`
  (SIGTERM from the kubelet after the liveness failures), **not** `OOMKilled`.
  `memory.events` shows `oom 0` and `oom_kill 0`.
- Pod events show the probes being refused, then the kubelet killing the container:

  ```text
  Warning  Unhealthy  Readiness probe failed: Get "http://<pod-ip>:8081/readyz": dial tcp <pod-ip>:8081: connect: connection refused
  Warning  Unhealthy  Liveness probe failed: Get "http://<pod-ip>:8081/healthz": dial tcp <pod-ip>:8081: connect: connection refused
  Normal   Killing    Container manager failed liveness probe, will be restarted
  ```

- `oc adm top pod` while it is stuck: about `43m` CPU (a sizeable part of the
  `100m` limit), `26Mi` memory.

## Evidence

### Startup attempts (standalone OLM install, no other software involved)

Each attempt deletes the manager pod and times the replacement to Ready. Memory
figures come from inside the container's cgroup (`/sys/fs/cgroup/memory.*`), read
about 20 s after Ready (or after the timeout). "Node" is anonymized.

| Attempt | Node | Page cache | Time to Ready | `memory.current` | `anon` | `file` | `workingset_refault_file` | Restarts | Log lines |
|---|---|---|---|---|---|---|---|---|---|
| 0 (install) | A | as found | ~12 s | 30.9 MB (98.3% of limit) | — | — | — | 0 | 16 |
| 1 | B | warm | 16 s | 11.8 MB | 10.8 MB | 0 | 0 | 0 | 16 |
| 2 | A | partly cold | 14 s | 27.3 MB | 13.6 MB | 12.9 MB | 3,152 | 0 | 16 |
| 3 | B | warm | 13 s | 12.8 MB | 11.8 MB | 0 | 0 | 0 | 16 |
| 4 | A | warm | 13 s | 13.4 MB | 12.6 MB | 0 | 0 | 0 | 16 |
| 5 | B | warm | 13 s | 12.8 MB | 11.7 MB | 0 | 0 | 0 | 16 |
| 6 | A | warm | 12 s | 14.3 MB | 13.6 MB | 0 | 0 | 0 | 16 |
| 7 | B | warm | 13 s | 12.4 MB | 11.6 MB | 0.09 MB | 0 | 0 | 16 |
| 8 | A | warm | 14 s | 14.5 MB | 13.7 MB | 0 | 0 | 0 | 16 |
| 9 | B | warm | 13 s | 12.8 MB | 11.8 MB | 0 | 0 | 0 | 16 |
| 10 | A | **cold** | **never** (180 s+) | 30.9 MB | 6.1 MB | 24.0 MB | 1,778,324 | 3 | 0 |
| 11 | B | **cold** | **never** | 30.7 MB | 6.6 MB | 23.5 MB | 1,748,730 | 3 | 0 |
| 12 | A | **cold** | **never** | 30.7 MB | 6.0 MB | 24.1 MB | 1,863,846 | 3 | 0 |
| 13 | B | **cold** | **never** | 30.8 MB | 6.3 MB | 23.8 MB | 1,879,530 | 3 | 0 |
| 14 | A | **cold** | **never** | 30.7 MB | 5.9 MB | 24.3 MB | 1,744,034 | 3 | 0 |
| 15 | B | **cold** | **never** | 30.8 MB | 6.2 MB | 23.9 MB | 1,751,345 | 3 | 0 |

`memory.peak` for every cold attempt was 31.41–31.43 MB, which is the 30Mi
(31,457,280-byte) limit. `memory.events` showed `max 0 oom 0 oom_kill 0` throughout.

Result: **9 of 9 warm starts were Ready in 12–16 s; 6 of 6 cold starts never became
Ready**, on both nodes.

### Controls: same pod spec, only the memory limit changed, cold cache

These are plain Deployments with exactly the MDR container spec (image digest,
command, args, probes, `OPERATOR_CONDITION_NAME` env, CPU `100m`, memory request
`20Mi`); only `limits.memory` differs.

| Memory limit | Time to Ready | `anon` | `file` | `workingset_refault_file` | `pgmajfault` | Notes |
|---|---|---|---|---|---|---|
| 30Mi (upstream) | never | ~6 MB | ~24 MB | ~1.8 M | 3,152 (attempt 12) | CrashLoop |
| 40Mi | ~22 s | 9.5 MB | 31.1 MB | 888,883 | 1,923 | Ready, but still thrashing (3 s gap between banner and `starting manager`) |
| 64Mi | ~12 s | 12.2 MB | 53.4 MB | 59 | 20 | Clean: the whole binary fits in cache |

### Key cgroup counters (`/sys/fs/cgroup/memory.stat`)

Warm start (attempt 1): nothing read from disk.

```text
anon 10842112
file 0
workingset_refault_file 0
pgscan_direct 0
pgmajfault 0
```

Cold start (attempt 12), stuck: the binary's pages are continually reclaimed and
read back in.

```text
anon 6017024
file 24137728
active_file 14942208
inactive_file 9117696
workingset_refault_file 1863846
workingset_activate_file 656300
pgscan_direct 1962747
pgsteal_direct 1863828
pgmajfault 3152
```

64Mi control: the whole 53 MB binary is resident and almost nothing is refaulted.

```text
anon 12161024
file 53440512
workingset_refault_file 59
pgmajfault 20
```

### Healthy startup log (warm cache, 30Mi), for comparison

Everything happens within about 3 s of the container starting. On a cold cache
**none** of these lines appear, not even the first one.

```text
INFO  setup  Go Version: go1.25.9
INFO  setup  Go OS/Arch: linux/amd64
INFO  setup  Operator Version: v0.7.0
INFO  setup  Git Commit: 39beef663ae7db0edd7d472362bbe445729e548d
INFO  setup  Build Date: 2026-06-17T12:54:44+00:00
INFO  setup  starting manager
INFO  controller-runtime.metrics  Starting metrics server
INFO  setup  disabling HTTP/2 support
INFO  starting server  {"name": "health probe", "addr": "[::]:8081"}
I ... leaderelection.go:257] attempting to acquire leader lease <ns>/285d4098.example.com...
INFO  controller-runtime.metrics  Serving metrics server  {"bindAddress": ":8443", "secure": true}
I ... leaderelection.go:271] successfully acquired lease <ns>/285d4098.example.com
INFO  Starting EventSource  {"controller": "machinedeletionremediation", ... "source": "kind source: *v1alpha1.MachineDeletionRemediation"}
INFO  Starting Controller   {"controller": "machinedeletionremediation", ...}
INFO  Starting workers      {"controller": "machinedeletionremediation", ..., "worker count": 1}
```

### Ruling out other causes

- **Not the application's working set.** The manager caches only
  `MachineDeletionRemediation` objects at startup; there were none in the cluster.
  Nodes and Machines are only read while a remediation is reconciled. On a warm
  cache the whole process uses about 11–14 MB.
- **Not an OOM kill.** `oom_kill 0`; exit code 2 after liveness kills. The limit is
  hit by reclaimable page cache, so the kernel reclaims and refaults instead of
  OOM-killing.
- **Not the node.** Cold starts failed 3 of 3 on each of two different nodes; warm
  starts succeeded on both.
- **Not node pressure.** Nodes were at 14–20% CPU and about 65% memory.
- **Not a particular deployment method.** We first saw it in a different install
  method that deploys the same Deployment spec. A standalone OLM install shows the
  same behaviour, and the Deployment specs match field for field (command, args,
  probes, resources, security context, volumes). The only difference is the
  `OPERATOR_CONDITION_NAME` env that OLM adds, which MDR doesn't read.

## Reproducer

Prerequisites:
- A **disposable** OpenShift 4.x cluster with OLM.
- `cluster-admin`, `oc`, `operator-sdk` (1.42 tested) and `jq`.
- Pass the kubeconfig explicitly:

```sh
KC=/path/to/disposable-cluster.kubeconfig
NS=mdr-repro
BUNDLE=quay.io/medik8s/machine-deletion-remediation-operator-bundle@sha256:b95a8e63056912168383bacdc13fd20a1df62d1ac9808978b127cf14871cf393
```

### 1. Install MDR v0.7.0 standalone

```sh
oc create namespace "$NS" --kubeconfig "$KC"
operator-sdk run bundle "$BUNDLE" --namespace "$NS" \
  --install-mode AllNamespaces --kubeconfig "$KC" --timeout 10m
oc get pods -n "$NS" -l control-plane=controller-manager -o wide --kubeconfig "$KC"
```

Whether this first start works depends on the node's cache.

### 2. Make the binary's page cache cold on the nodes

This evicts only the MDR binary's pages: `dd iflag=nocache` with `count=0` calls
`posix_fadvise(DONTNEED)` on the file. The file is the `manager` binary in the
image's top layer.

```sh
# Find the binary on a node that runs (or has run) the MDR pod:
NODE=<node-name>
oc debug node/"$NODE" -q --kubeconfig "$KC" -- chroot /host sh -c \
  'find /var/lib/containers/storage/overlay -path "*/diff/manager" -size +50M 2>/dev/null'

# Check how much of it is cached (expect ~53M resident when warm):
oc debug node/"$NODE" -q --kubeconfig "$KC" -- chroot /host fincore <path-from-above>

# Evict just that file from the page cache:
oc debug node/"$NODE" -q --kubeconfig "$KC" -- chroot /host sh -c \
  'dd if=<path-from-above> iflag=nocache count=0 status=none; fincore <path-from-above>'
```

Repeat this on every node the pod can schedule to.

Simpler alternative on a throwaway node: `chroot /host sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'`
drops the whole node's page cache.

A real-world way to get a cold cache: reboot the node, or start the pod on a node
that has just pulled the image.

### 3. Restart the manager and watch it fail

```sh
oc delete pod -n "$NS" -l control-plane=controller-manager --kubeconfig "$KC"
oc get pods -n "$NS" -l control-plane=controller-manager -w --kubeconfig "$KC"
# expect: 0/1 Running, RESTARTS climbing about once a minute, never Ready
```

### 4. Collect the evidence

```sh
POD=$(oc get pod -n "$NS" -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}' --kubeconfig "$KC")
oc logs "$POD" -n "$NS" --kubeconfig "$KC"                # empty
oc logs "$POD" -n "$NS" --previous --kubeconfig "$KC"     # empty
oc get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].lastState}' --kubeconfig "$KC"
                                                           # terminated, exitCode 2, reason Error
oc get events -n "$NS" --field-selector involvedObject.name="$POD" --kubeconfig "$KC"
oc exec "$POD" -n "$NS" --kubeconfig "$KC" -- cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events
oc exec "$POD" -n "$NS" --kubeconfig "$KC" -- cat /sys/fs/cgroup/memory.stat | \
  grep -E '^(anon|file|workingset_refault_file|pgscan_direct|pgmajfault) '
```

`oc exec` works between liveness kills, because the image includes `sh` and `cat`.
Expect `memory.peak` at about 31.4 MB, `file` at about 24 MB and
`workingset_refault_file` in the millions.

### 5. Confirm the limit is the cause (optional control)

Create a plain Deployment with the same container spec and only a larger memory
limit, then repeat steps 2–3 for it:

```sh
oc get deploy machine-deletion-remediation-controller-manager -n "$NS" -o json --kubeconfig "$KC" | \
  jq '{apiVersion, kind, metadata: {name: "mdr-control-64mi", namespace: .metadata.namespace},
       spec: {replicas: 1, selector: {matchLabels: {app: "mdr-control-64mi"}},
              template: {metadata: {labels: {app: "mdr-control-64mi"}},
                         spec: (.spec.template.spec
                                | .containers[0].resources.limits.memory = "64Mi")}}}' | \
  oc apply -f - --kubeconfig "$KC"
```

It reaches Ready in about 12 s with a cold cache. Use `40Mi` to see the marginal
case (Ready in about 22 s, still about 0.9 M refaults). Both controls run their own
leader election in the same namespace, so delete them afterwards.

### 6. Clean up

```sh
oc delete deploy mdr-control-64mi -n "$NS" --kubeconfig "$KC" --ignore-not-found
operator-sdk cleanup machine-deletion-remediation --namespace "$NS" --kubeconfig "$KC"
oc delete namespace "$NS" --kubeconfig "$KC"
oc get clusterrole -o name --kubeconfig "$KC" | grep machine-deletion-remediation   # delete leftovers, e.g. metrics-reader
```

## Suggested fix

Raise the manager's memory limit in `config/manager/manager.yaml`, and so in the
bundle CSV, to at least `64Mi`. That is the smallest value we tested that is clean
on a cold cache. A request of `20Mi` can stay; the warm working set is 11–14 MB.

Some headroom (for example `128Mi`) would also cover a larger binary in future
builds. Alternatively, a smaller binary (`-ldflags="-s -w"`, if not already used)
would reduce the cold-start footprint, but the limit would still be tight.

## Limitations of this analysis

- Tested on one OpenShift 4.22.1 cluster (RHCOS 9.8, cgroup v2, CRI-O 1.35). The
  charging behaviour is standard cgroup v2 page-cache accounting, so it should
  apply to any cgroup v2 Kubernetes, but we have not tried others.
- Downstream builds (Red Hat Workload Availability) were not tested; they may use a
  different limit or binary size.
- The cold cache was produced deliberately by evicting the binary's pages. In the
  automated install runs that first showed the problem, nothing was evicted
  manually; the cache was just cold.

---

## Draft issue text

**Title:** Manager CrashLoops on a cold page cache: 30Mi memory limit is smaller than the 53 MB binary (v0.7.0)

**Body:**

> **What happened**
>
> On OpenShift 4.22 (cgroup v2), the MDR v0.7.0 manager sometimes never becomes
> Ready. The container prints no logs at all, never opens `:8081`, and is killed
> by the liveness probe every ~60 s (exit code 2, not OOMKilled). It depends on
> whether the `/manager` binary is already in the node's page cache.
>
> **Why**
>
> The manager's memory limit is `30Mi` (`config/manager/manager.yaml`), but the
> binary is ~53 MB. On cgroup v2, the binary's page-cache pages are charged to the
> container when it is the first to read them. With a cold cache, ~24 MB of binary
> pages plus ~6 MB anonymous memory reach the limit before `main()` runs. The
> kernel then thrashes: `workingset_refault_file` reaches ~1.8 million and
> `pgscan_direct` ~2 million within a container lifetime, and startup never
> completes. With a warm cache (pages charged to an earlier cgroup), the same pod
> uses ~12 MB and is Ready in ~13 s.
>
> **Evidence** (standalone OLM install of
> `machine-deletion-remediation-operator-bundle@sha256:b95a8e63…`)
>
> - Warm cache: 9/9 starts Ready in 12–16 s, `memory.current` 11.8–14.5 MB, `file` 0.
> - Cold cache (binary evicted with `dd iflag=nocache count=0`): 6/6 starts never
>   Ready on two nodes. `memory.peak` was 31.4 MB (the limit), `file` ~24 MB,
>   `workingset_refault_file` 1.74–1.88 M, `oom_kill` 0, logs empty.
> - Same pod spec, only the limit changed: 40Mi was Ready in ~22 s but still
>   thrashing (0.9 M refaults); 64Mi was Ready in ~12 s with 59 refaults.
>
> **Reproduce**
>
> 1. Install v0.7.0 with OLM (AllNamespaces).
> 2. Evict the manager binary from the page cache on the nodes (`posix_fadvise`
>    DONTNEED via `dd if=<overlay>/diff/manager iflag=nocache count=0`, or drop
>    caches), or reboot the node.
> 3. Delete the manager pod. It never becomes Ready, logs are empty, and restarts
>    climb about once a minute.
>
> **Suggested fix**
>
> Raise `limits.memory` to at least `64Mi` (or `128Mi` for headroom). The request
> can stay at `20Mi`.
>
> **Environment:** OpenShift 4.22.1, RHCOS 9.8 (kernel 5.14.0-687), CRI-O 1.35.4,
> cgroup v2, amd64. MDR v0.7.0, image `sha256:0f69367097…`, built with go1.25.9.
