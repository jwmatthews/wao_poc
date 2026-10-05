# Tutorial: building and verifying the WAO POC (outline)

> Status: **outline**. Each section lists the goal, the commands and the checks that
> show it worked. The prose will be filled in later.

This tutorial walks through how the Workload Availability Operator (WAO) POC was
built and tested. WAO installs the six upstream medik8s operators (NHC, SNR, SBR,
FAR, MDR and NMO) as operands from one OLM bundle. Read
[docs/design-brief.md](docs/design-brief.md) and
[docs/implementation-plan.md](docs/implementation-plan.md) alongside it.

Throughout, `KC` is the path to a **disposable** cluster's kubeconfig and is always
passed explicitly:

```sh
KC=/path/to/disposable-cluster.kubeconfig
oc get nodes --kubeconfig "$KC"
```

---

## 0. Ground rules and workflow

- The hard constraints in [AGENTS.md](AGENTS.md):
  - Components are consumed unchanged, by digest.
  - Every component defaults to `Disabled`.
  - Webhook `failurePolicy` is never changed.
  - WAO never adopts objects it did not create.
- Keeping secrets out of Git:
  - `*.kubeconfig`, `DISPOSABLE_OPENSHIFT_CLUSTERS.md`, `.cache/`, `evidence/`,
    `dist/` and `.venv/` are git-ignored.
  - Before every commit, check what is staged:
    ```sh
    git add -A
    git diff --cached --name-only | grep -E 'kubeconfig|DISPOSABLE|^bin/|\.cache|evidence|\.venv|__pycache__|^dist/'
    ```
- The test-first loop for every task: write a failing test, watch it fail,
  implement, watch it pass, run `make test` (and `make test-offline` from Task 3
  on), then commit with a `wao:` message.
- Work on a branch and never push without review:
  `git switch -c wao-poc-impl`.
- (Optional) How this run was organized: one orchestrator session and one subagent
  per task. The orchestrator checked every task's output itself before starting
  the next.

## 1. Prepare the test cluster

- Goal: a cluster with no medik8s operators, CRDs or namespaces, so the preflight
  can pass.
- Inspect what is already installed:
  ```sh
  oc get crd --kubeconfig "$KC" | grep medik8s
  oc get subs -A --kubeconfig "$KC"
  oc get csv -A --kubeconfig "$KC" | grep -i -E 'remediation|healthcheck|maintenance|fence'
  ```
- Remove a pre-existing install in this order:
  1. Subscriptions, then CSVs.
  2. Custom resources (SNR config and template).
  3. The CRDs.
  4. Leftover ClusterRoles, bindings and the ConsolePlugin.
  5. The operator namespaces and `medik8s-leases`.
- Check that the cluster operators are still healthy:
  ```sh
  oc get co --kubeconfig "$KC"
  ```
- Lesson: keep a stable copy of the kubeconfig outside the repo. In this run, a
  parallel scaffold step temporarily moved the repo files and the kubeconfig with
  them.

## 2. Task 1: scaffold the operator

- Install the toolchain:
  ```sh
  brew install operator-sdk
  operator-sdk version; go version
  ```
- operator-sdk only initializes an empty directory. Move everything else aside
  first, including `.gitignore`, the kubeconfigs and the clusters file:
  ```sh
  operator-sdk init --domain medik8s.io --repo github.com/jwmatthews/wao_poc \
    --project-name workload-availability-operator
  operator-sdk create api --group workloadavailability --version v1alpha1 \
    --kind WorkloadAvailabilityConfig --resource --controller
  ```
- Make the API cluster-scoped: add
  `+kubebuilder:resource:scope=Cluster,shortName=wac` and set `namespaced: false`
  in `PROJECT`.
- Restore the files you moved and merge `.gitignore`, since the scaffold
  overwrites it.
- Check:
  ```sh
  make generate manifests build test
  ```

## 3. Task 2: the `WorkloadAvailabilityConfig` API

- Spec: six components, each with a `state` that defaults to `Disabled`.
- Status: conditions, a per-component phase, `retainedResources` and `releaseSet`.
- A CEL rule makes the config a singleton named `cluster`.
- Test first:
  ```sh
  go test ./api/... -run TestStateOf
  make generate manifests
  ```
- Gotcha: from now on, envtest objects must be named `cluster`.

## 4. Task 3: fetch the bundles and extract the operand manifests

- Set up Python:
  ```sh
  python3 -m venv .venv && .venv/bin/pip install -r hack/requirements.txt
  ```
- Fetch the pinned bundles anonymously from quay.io. Every blob is checked
  against its digest.
  ```sh
  make bundles   # hack/fetch-bundles.py -> .cache/bundles/<component>/
  ```
- Extraction (`hack/extract-operand-manifests.py`), test first:
  ```sh
  .venv/bin/python -m unittest hack/extract_operand_manifests_test.py -v
  make operand-manifests
  make operand-manifests-check   # prints "outputs current"
  ```
- What extraction produces:
  - per-component manifests with a namespace placeholder;
  - the 12 component CRDs;
  - the union role (D7);
  - `provenance.json`;
  - service-ca webhook wiring (D1);
  - narrowed Service selectors (D10).
- Plan bugs fixed here:
  - Optional webhook fields (NMO's `timeoutSeconds`) were dropped.
  - The union role must contain every rule of every role WAO creates, or
    Kubernetes RBAC escalation checks reject them.
- Check: the webhook `failurePolicy` values match the bundles exactly.

## 5. Task 4: image set, component registry and renderer

- `internal/images`: the seven `RELATED_IMAGE_*` variables, validated at startup.
- `internal/components`: one definition per component (Deployments, webhooks,
  agent owners, managed kinds).
- `internal/operands`: renders the embedded manifests, replaces tags with pinned
  digests and adds the component labels.
- Check: no upstream image tag is left after rendering.
  ```sh
  go test ./internal/images/... ./internal/components/... ./internal/operands/...
  ```

## 6. Task 5: the controller, with envtest

- Write the status summarizer test first, then 10 envtest specs.
- Reconcile loop:
  - server-side apply with field owner `workload-availability-operator`;
  - owner references only on objects WAO renders;
  - a foreign-object guard that refuses to adopt objects WAO did not create;
  - `DisableIncomplete` reporting with `retainedResources`.
- Check, twice, to catch flakes:
  ```sh
  make test
  ```

## 7. Task 6: manager wiring and the default config

- `cmd/main.go`:
  - exit at startup if any image variable or `OPERATOR_NAMESPACE` is missing;
  - namespace-scoped caches;
  - create the default config once this replica is the leader.
- `config/manager/manager.yaml` carries the pinned `RELATED_IMAGE_*` values.
- Check that startup refuses to run without them:
  ```sh
  OPERATOR_NAMESPACE=x go run ./cmd   # expect: lists the missing image variables, exits 1
  bin/kustomize build config/default | head
  ```
- Add `*.kubeconfig` and `DISPOSABLE_OPENSHIFT_CLUSTERS.md` to `.dockerignore`.

## 8. Task 7: the CSV and bundle

- Write the CSV base by hand: package `workload-availability-operator`, channel
  `alpha`, `AllNamespaces` only, 13 owned CRDs.
- Build and check the bundle:
  ```sh
  make bundle IMG=<image> VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
  make bundle-check
  operator-sdk bundle validate ./bundle --select-optional suite=operatorframework
  ```
- Gotchas:
  - Take the helper admin, editor and viewer ClusterRoles out of the bundle.
  - Run `rm -rf bundle/manifests` before regenerating.
  - `relatedImages` doesn't list the WAO image itself.

## 9. Task 8: build the image on the cluster and create the catalog

- Why build on the cluster: the internal registry needs no external credentials
  and builds natively for amd64.
- Build in a separate namespace, not the install namespace, so the preflight still
  finds that namespace absent:
  ```sh
  SRC=$(mktemp -d) && git archive HEAD | tar -x -C "$SRC"   # never --from-dir=.
  oc create namespace wao-poc-build --kubeconfig "$KC"
  oc new-build --binary --name wao -n wao-poc-build --strategy docker --kubeconfig "$KC"
  oc policy add-role-to-group system:image-puller \
    system:serviceaccounts:openshift-workload-availability -n wao-poc-build --kubeconfig "$KC"
  oc start-build wao -n wao-poc-build --from-dir="$SRC" --follow --kubeconfig "$KC"
  DIGEST=$(oc get istag wao:latest -n wao-poc-build --kubeconfig "$KC" -o jsonpath='{.image.metadata.name}')
  IMG=image-registry.openshift-image-registry.svc:5000/wao-poc-build/wao@$DIGEST
  ```
- Regenerate the bundle and render the catalog:
  ```sh
  make bundle IMG=$IMG VERSION=0.1.0 CHANNELS=alpha DEFAULT_CHANNEL=alpha
  make bundle-check
  make catalog-configmap DEFAULT_CHANNEL=alpha   # -> dist/wao-poc-catalog.yaml
  ```

## 10. Task 9: the live-cluster test harness

- One script per case, `test/cluster/NN-*.sh`, where `NN` matches `WAO-INST-NN`.
- Shared helpers in `env.sh` and `lib.sh`: `record`, `wait_for`, `expect`,
  `snapshot`.
- `parity.py` checks the live objects against the upstream CSV; `results.py`
  writes `results.json`.
- Safety:
  - admission checks use `--dry-run=server` only;
  - no real remediation, NodeMaintenance or NHC policy is ever created;
  - Secrets are checked by key name only, never by value.
- Lesson: make checks fail when the API call fails. Several of the plan's checks
  passed on error.
- Check offline:
  ```sh
  make test-offline
  ```

## 11. Run the live verification

- Run every case:
  ```sh
  RUN_DIR=evidence/$(date -u +%F)-wao-poc-run1 KUBECONFIG="$KC" bash test/cluster/run-all.sh
  KUBECONFIG="$KC" bash test/cluster/run-all.sh 00   # read-only preflight only
  ```
- Read the results:
  - `evidence/<run>/results.json`
  - `evidence/<run>/raw/case-NN.log`
- Sort every failure into one of three classes: harness bug, WAO bug, or
  environment/upstream.
- The case list (00–18): preflight, catalog, install, clean-install invariants,
  default config, enabling each of the six components, parity, restart, drift,
  disable, deleting the config, and uninstall.

## 12. Debug the failures (four runs)

| Run | Score | Finding | Fix |
| --- | --- | --- | --- |
| 1 | 18/19 | FAR webhook timed out: FAR couldn't list Secrets cluster-wide | WAO: grant CSV `permissions` cluster-wide, as OLM does |
| 2 | 16/19 | FAR's dry-run template was invalid for FAR v0.8.0 | Harness: add a `nodeparameters` entry |
| 3 | 18/19 | NMO crash-looped | WAO: add OLM's `namespaces get/list/watch` rule |
| 4 | 17/19 | MDR never started (cold page cache) | Upstream: 30Mi memory limit |

- Debugging commands:
  ```sh
  oc logs deploy/<manager> -n openshift-workload-availability --previous --kubeconfig "$KC"
  oc auth can-i list namespaces \
    --as=system:serviceaccount:openshift-workload-availability:<sa> --kubeconfig "$KC"
  oc get wac cluster -o yaml --kubeconfig "$KC"
  ```
- After each WAO fix:
  1. Write a failing test.
  2. Regenerate the manifests.
  3. Rebuild the image.
  4. Regenerate the bundle and catalog.
  5. Rerun the live cases.

## 13. Before blaming upstream, compare with a standalone OLM install

- Technique: install the exact pinned bundle without WAO and compare it with what
  WAO deploys.
  ```sh
  oc create namespace nmo-standalone-test --kubeconfig "$KC"
  operator-sdk run bundle quay.io/medik8s/node-maintenance-operator-bundle@sha256:<digest> \
    --namespace nmo-standalone-test --install-mode AllNamespaces --kubeconfig "$KC" --timeout 10m
  # watch restarts and logs; diff the OLM-created ClusterRoles against internal/operands/manifests/nmo/
  operator-sdk cleanup node-maintenance-operator --namespace nmo-standalone-test --kubeconfig "$KC"
  ```
- NMO: standalone ran with 0 restarts, so the crash loop was a WAO bug. OLM
  quietly adds a namespaces rule.
- MDR: standalone failed the same way, so it is a real upstream defect.
  - Force cold and warm starts.
  - Measure `memory.current` and refaults.
  - Use limit-raised controls at 40Mi and 64Mi.

## 14. Task 10: documentation and wrap-up

- README: status, toolchain, build, install, the meaning of Disabled, uninstall,
  security notes, known upstream issues and deviations from the plan.
- Check the docs against the code: object names in `docs/operands.md`, and the
  D1–D10 references in code comments.
- Write a sanitized `REPORT.md` in `evidence/` (no URLs, node names, IPs or UIDs).
  Commit sanitized results only after review.
- Leave the cluster clean: the final preflight must pass, with `wao-poc-build`
  kept for rebuilds.

## Appendix

- Command quick reference: `make bundles operand-manifests-check generate manifests test test-offline bundle bundle-check catalog-configmap`
- Where things live:
  - operand manifests: `internal/operands/manifests/`
  - controller: `internal/controller/`
  - harness: `test/cluster/`
  - evidence (git-ignored): `evidence/`
- Further reading: the [README](README.md) sections "Deviations from the plan" and
  "Known upstream issues".
