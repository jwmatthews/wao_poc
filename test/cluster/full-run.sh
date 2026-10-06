#!/usr/bin/env bash
# test/cluster/full-run.sh — run the POC on a disposable cluster, in phases or end to end:
#
#   build    confirm the cluster, workstation checks, read-only preflight, build the WAO image on the
#            cluster from `git archive HEAD`, point the bundle at it, render dist/wao-poc-catalog.yaml
#   install  confirm, then WAO-INST-00..02: catalog, install WAO through OLM, approve the InstallPlan.
#            Leaves WAO installed with every component Disabled, ready for `oc patch`.
#   run      confirm, then WAO-INST-00..18 (install, enable all six, parity, restart, drift, disable,
#            uninstall) and write a sanitized REPORT.md skeleton
#   all      build, then run (the default)
#
# `install` and `run` need the image in the cluster and dist/wao-poc-catalog.yaml from `build`.
# Clean up after `install` with `bash test/cluster/run-all.sh 18`. Never commits or pushes.
# It is the scripted form of docs/agent-test-run.md.
#
# Usage: CONFIRM=yes KUBECONFIG=/path/to/disposable.kubeconfig bash test/cluster/full-run.sh [build|install|run|all]
# Environment:
#   CONFIRM=yes        skip the interactive confirmation (required when stdin is not a terminal)
#   SKIP_PREREQS=1     build: skip make bundles/operand-manifests-check/test/test-offline
#   SKIP_BUILD=1       build: reuse the image already in the cluster (istag wao:latest in BUILD_NS)
#   ALLOW_DIRTY=1      build: proceed with uncommitted changes (the build ships `git archive HEAD`)
#   WAO_VERSION=0.1.0  bundle version; must match CSV_NAME in env.sh
#   RUN_DIR, BUILD_NS, CATALOG_FILE, STOP_ON_FAIL, SKIP_CLEANUP as in run-all.sh and env.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE="${1:-all}"
case "$PHASE" in
  build|install|run|all) ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) echo "usage: $0 [build|install|run|all]" >&2; exit 2 ;;
esac
: "${KUBECONFIG:?set KUBECONFIG to a disposable OpenShift cluster you are authorized to modify}"
export RUN_DIR="${RUN_DIR:-$(cd "$HERE/../.." && pwd)/evidence/$(date -u +%F)-wao-poc}"
source "$HERE/lib.sh"
WAO_VERSION="${WAO_VERSION:-0.1.0}"
REGISTRY=image-registry.openshift-image-registry.svc:5000
LOG="$RUN_DIR/full-run.log"
exec > >(tee -a "$LOG") 2>&1
cd "$REPO_ROOT"

step() { echo; echo "######## $(date -u +%FT%TZ) $*"; }
die() { echo "ERROR: $*" >&2; exit 2; }
# oc without the 30s request timeout `k` applies, for the build log stream.
oc_long() { "${OC}" --kubeconfig "${KUBECONFIG}" "$@"; }

# ---- confirm the cluster (every phase) ----------------------------------------------------------
confirm() {
  step "confirm the cluster (phase: $PHASE)"
  user=$(k whoami) || die "cannot talk to the cluster with KUBECONFIG=$KUBECONFIG"
  version=$(k get clusterversion version -o jsonpath='{.status.desired.version}')
  topology=$(k get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
  nodes=$(k get nodes -o name | wc -l | tr -d ' ')
  cat <<EOF
kubeconfig : $KUBECONFIG
user       : $user
OpenShift  : $version, $nodes nodes, topology $topology
evidence   : $RUN_DIR (git-ignored; raw output contains cluster-identifying details)

EOF
  case "$PHASE" in
    build) echo "This phase MUTATES the cluster: it builds an image in namespace $BUILD_NS." ;;
    install) echo "This phase MUTATES the cluster: it applies the catalog and installs WAO through OLM in $NS."
             echo "Clean up afterwards with: bash test/cluster/run-all.sh 18" ;;
    run|all) cat <<EOF
This run MUTATES the cluster: it builds an image in namespace $BUILD_NS (build phase), installs WAO through
OLM in $NS, enables all six components (WAO-INST-06 starts privileged SNR agents on every eligible node),
then uninstalls WAO and deletes the thirteen medik8s CRDs and every custom resource of those kinds.
EOF
    ;;
  esac
  echo "Only use a disposable cluster you are authorized to modify."
  if [ "${CONFIRM:-}" != yes ]; then
    [ -t 0 ] || die "not a terminal; set CONFIRM=yes after confirming the cluster is disposable"
    printf 'Type yes to continue: '; read -r answer
    [ "$answer" = yes ] || die "not confirmed"
  fi
}

# ---- build: prerequisites, preflight, on-cluster build, bundle, catalog ---------------------------
phase_build() {
  step "workstation prerequisites"
  commit=$(git rev-parse HEAD)
  dirty_before=$(git status --porcelain | sort)
  if [ -n "$dirty_before" ]; then
    echo "uncommitted changes (the build ships git archive HEAD=$commit, not the working tree):"
    echo "$dirty_before"
    [ "${ALLOW_DIRTY:-0}" = 1 ] || die "commit or stash first, or set ALLOW_DIRTY=1"
  fi
  [ -x "$PYTHON" ] || die "$PYTHON missing: python3 -m venv .venv && .venv/bin/pip install -r hack/requirements.txt"
  if [ "${SKIP_PREREQS:-0}" = 1 ]; then
    echo "SKIP_PREREQS=1: skipping make bundles operand-manifests-check test test-offline"
  else
    make bundles operand-manifests-check
    make test
    make test-offline
  fi
  k get --raw /apis/build.openshift.io/v1 >/dev/null || die "the cluster has no Build API (builds capability); cannot build the image on it"

  step "preflight (read-only, image check skipped)"
  SKIP_IMAGE_CHECK=1 bash "$HERE/run-all.sh" 00

  step "build the WAO image in namespace $BUILD_NS"
  if [ "${SKIP_BUILD:-0}" = 1 ]; then
    echo "SKIP_BUILD=1: reusing istag wao:latest in $BUILD_NS"
  else
    absent namespace "$BUILD_NS" && record build-create-ns create namespace "$BUILD_NS" >/dev/null
    if absent buildconfig wao -n "$BUILD_NS"; then
      record build-new-build new-build --binary --name wao -n "$BUILD_NS" --strategy docker >/dev/null
    fi
    # Let pods in the install namespace pull from the build namespace (works before it exists).
    record build-image-puller policy add-role-to-group system:image-puller \
      "system:serviceaccounts:${NS}" -n "$BUILD_NS" >/dev/null
    src=$(mktemp -d)
    git archive HEAD | tar -x -C "$src"
    echo "uploading git archive of $commit"
    oc_long start-build wao -n "$BUILD_NS" --from-dir="$src" --follow --wait
    rm -rf "$src"
  fi
  digest=$(k get istag wao:latest -n "$BUILD_NS" -o jsonpath='{.image.metadata.name}')
  case "$digest" in sha256:*) ;; *) die "no image digest for istag wao:latest in $BUILD_NS (got '$digest')" ;; esac
  img="${REGISTRY}/${BUILD_NS}/wao@${digest}"
  echo "image: $img"
  { echo; echo "## Build $(date -u +%FT%TZ)"; echo "- Commit: ${commit}"; echo "- Image: ${img}"; } >> "$RUN_DIR/RUN.md"

  step "regenerate the bundle for $img"
  make bundle IMG="$img" VERSION="$WAO_VERSION" CHANNELS=alpha DEFAULT_CHANNEL=alpha
  # README quotes the digest the committed bundle references; keep it current.
  sed -i.bak -E "s#${REGISTRY}/${BUILD_NS}/wao@sha256:[0-9a-f]{64}#${img}#" README.md && rm -f README.md.bak
  make bundle-check
  grep -q "image: ${img}" bundle/manifests/workload-availability-operator.clusterserviceversion.yaml \
    || die "bundle CSV does not reference $img"
  local allowed dirty_after new_changes unexpected
  allowed="README.md
bundle/manifests/workload-availability-operator.clusterserviceversion.yaml
config/manager/kustomization.yaml"
  dirty_after=$(git status --porcelain | sort)
  new_changes=$(comm -13 <(echo "$dirty_before") <(echo "$dirty_after") | sed 's/^...//' | sort)
  unexpected=$(comm -23 <(echo "$new_changes") <(echo "$allowed" | sort) | sed '/^$/d')
  if [ -n "$unexpected" ]; then
    echo "make bundle changed files outside the expected set:"; echo "$unexpected"
    die "understand that diff before continuing (git diff)"
  fi
  # A rebuild with the same digest only bumps the CSV createdAt timestamp; keep the tree clean then.
  local csv=bundle/manifests/workload-availability-operator.clusterserviceversion.yaml
  if [ "$(git diff -- "$csv" | grep -c '^[-+][^-+]')" = 2 ] && ! git diff -- "$csv" | grep -q '^+.*image:'; then
    git checkout -- "$csv"; echo "bundle CSV: only createdAt changed, restored"
  fi
  echo "bundle changes:"; git diff --stat -- README.md bundle config/manager
  make catalog-configmap DEFAULT_CHANNEL=alpha
  cat <<EOF

######## build done
image   : $img
catalog : $CATALOG_FILE
bundle  : now references the image above (git diff -- README.md bundle config/manager)
Next    : bash test/cluster/full-run.sh install   (WAO only)   or   bash test/cluster/full-run.sh run   (all cases)
To commit the bundle update after review (never evidence/):
  git add README.md bundle/manifests/workload-availability-operator.clusterserviceversion.yaml config/manager/kustomization.yaml
  git commit -m "wao: point bundle at rebuilt image ${digest:7:12}" -- README.md bundle config/manager
EOF
}

need_catalog() {
  [ -f "$CATALOG_FILE" ] || die "$CATALOG_FILE missing; run \`bash test/cluster/full-run.sh build\` first"
}

# ---- install: WAO-INST-00..02, leave WAO installed ----------------------------------------------
phase_install() {
  need_catalog
  step "install WAO (WAO-INST-00..02)"
  bash "$HERE/run-all.sh" 00 01 02
  step "installed"
  k get csv -n "$NS"
  k get workloadavailabilityconfig cluster -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.phase}{"\n"}{end}' || true
  cat <<EOF

######## install done
WAO is installed in $NS with every component Disabled. Enable one with, for example:
  oc patch workloadavailabilityconfig cluster --type merge --kubeconfig "\$KUBECONFIG" \\
    -p '{"spec":{"components":{"nodeHealthCheck":{"state":"Enabled"}}}}'
Run more cases into the same evidence dir:   bash test/cluster/run-all.sh 03 04 05
Uninstall and clean up:                      bash test/cluster/run-all.sh 18
EOF
}

# ---- run: WAO-INST-00..18 and the report --------------------------------------------------------
phase_run() {
  need_catalog
  step "run WAO-INST-00..18"
  run_code=0
  bash "$HERE/run-all.sh" || run_code=$?

  step "write REPORT.md"
  local commit img node_names report leaks
  commit=$(git rev-parse HEAD)
  img=$(grep -m1 -Eo 'image: image-registry\.openshift-image-registry\.svc:5000/[^ ]+' \
    bundle/manifests/workload-availability-operator.clusterserviceversion.yaml | sed 's/^image: //' || echo "not in the internal registry")
  node_names=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)
  "$PYTHON" - "$RUN_DIR" "$commit" "$img" "$version" "$topology" "$nodes" "$run_code" <<'PY'
import json, pathlib, sys
run, commit, img, version, topology, nodes, code = sys.argv[1:8]
run = pathlib.Path(run)
cases = json.loads((run / "results.json").read_text())
counts = {s: sum(1 for c in cases if c["status"] == s) for s in ("pass", "fail", "blocked")}
lines = [
    "# WAO POC live-cluster run report", "",
    f"- OpenShift: {version}, {nodes} nodes, topology {topology}",
    f"- Commit: {commit}",
    f"- Image: {img}",
    f"- Result: {counts['pass']} pass, {counts['fail']} fail, {counts['blocked']} blocked (run-all exit {code})", "",
    "## Cases", "", "| Case | Status | Notes |", "| --- | --- | --- |",
]
for c in cases:
    notes = (c.get("notes") or "").replace("|", "\\|").replace("\n", " ")
    lines.append(f"| {c['id']} | {c['status']} | {notes} |")
left = [c for c in cases if "LEFTOVER" in (c.get("notes") or "")]
lines += ["", "## Leftovers after cleanup", ""]
lines += [f"- {c['id']}: {c['notes']}" for c in left] or ["- none reported"]
lines += ["", "## Deviations", "", "- (fill in: skipped steps, manual interventions, re-runs)", ""]
(run / "REPORT.md").write_text("\n".join(lines))
print("\n".join(lines[:6]))
PY
  report="$RUN_DIR/REPORT.md"
  leaks=$(grep -nE 'https?://|:6443|\.apps\.|(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}($|[^0-9.])|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}' "$report" || true)
  if [ -n "$node_names" ]; then
    leaks="${leaks}$(grep -nF "$node_names" "$report" || true)"
  fi
  if [ -n "$leaks" ]; then
    echo "REPORT.md contains cluster-identifying text; sanitize before it leaves evidence/:"; echo "$leaks"
  else
    echo "REPORT.md sanitization check: clean"
  fi
  cat <<EOF

######## run done (run-all exit $run_code)
results : $RUN_DIR/results.json
report  : $report (review and complete the Deviations section)
log     : $LOG
EOF
  return "$run_code"
}

confirm
code=0
case "$PHASE" in
  build) phase_build ;;
  install) phase_install ;;
  run) phase_run || code=$? ;;
  all) phase_build; phase_run || code=$? ;;
esac
exit "$code"
