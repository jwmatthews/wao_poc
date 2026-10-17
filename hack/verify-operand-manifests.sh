#!/usr/bin/env bash
# Offline checks that the committed operand files, release-set.yaml, the manager Deployment and the
# bundle agree. CI runs this; it needs no network and no cluster.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
YQ=${YQ:-bin/yq}; [ -x "$YQ" ] || YQ=yq
KUSTOMIZE=${KUSTOMIZE:-bin/kustomize}; [ -x "$KUSTOMIZE" ] || KUSTOMIZE=kustomize
RS=release-set.yaml
fail=0; problem() { echo "verify-operand-manifests: $*" >&2; fail=1; }

# 1. Stamps match release-set.yaml.
for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  stamp=config/operands/$k/UPSTREAM.yaml
  [ -f "$stamp" ] || { problem "$stamp missing"; continue; }
  for f in repo version tag commit; do
    want=$("$YQ" ".components.$k.$f" "$RS"); got=$("$YQ" ".$f" "$stamp")
    [ "$want" = "$got" ] || problem "$k: $f is $got in $stamp but $want in $RS; run make update-operand-manifests"
  done
done

# 2. Rendering the committed overlays reproduces the committed outputs.
make -s operand-manifests
if ! git diff --quiet -- internal/operands/manifests config/operands config/manager/manager.yaml; then
  git --no-pager diff --stat -- internal/operands/manifests config/operands config/manager/manager.yaml >&2
  problem "rendered outputs differ from the committed ones; run make operand-manifests and commit"
fi

# 3. RELATED_IMAGE_* equal the pinned digests.
for env in $("$YQ" '[.components[].images | keys | .[]] | .[]' "$RS"); do
  want=$("$YQ" ".components[].images.$env.pinned // \"\"" "$RS" | grep .)
  got=$("$YQ" "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$env\") | .value" config/manager/manager.yaml)
  [ "$want" = "$got" ] || problem "manager.yaml $env=$got, release-set.yaml pins $want"
done

# 4. Every operand ServiceAccount is in OPERAND_SERVICE_ACCOUNTS.
extra=$(sed -n 's/^OPERAND_SERVICE_ACCOUNTS := //p' Makefile | tr ',' '\n')
for k in $("$YQ" '.components | keys | .[]' "$RS"); do
  errf=$(mktemp)
  if ! rbac=$("$KUSTOMIZE" build "config/operands/$k/rbac" 2>"$errf"); then
    problem "$k: kustomize build config/operands/$k/rbac failed: $(tail -1 "$errf")"; rm -f "$errf"; continue
  fi
  rm -f "$errf"
  sas=$(printf '%s\n' "$rbac" | "$YQ" -N 'select(.kind == "ServiceAccount") | .metadata.name')
  [ -n "$sas" ] || problem "$k: no ServiceAccount in config/operands/$k/rbac"
  for sa in $sas; do
    grep -qx "$sa" <<<"$extra" || problem "$k: ServiceAccount $sa is not in OPERAND_SERVICE_ACCOUNTS; its roles would become standalone bundle files"
  done
done

# 5. The bundle carries no standalone Role, RoleBinding or ServiceAccount, and only known ClusterRoles.
for f in bundle/manifests/*.yaml; do
  kind=$("$YQ" '.kind' "$f")
  case "$kind" in
    ClusterServiceVersion|CustomResourceDefinition) ;;
    ClusterRole) name=$("$YQ" '.metadata.name' "$f")
      case "$name" in *-metrics-reader|*-ext-remediation|*-admin-role|*-editor-role|*-viewer-role) ;; *) problem "unexpected standalone ClusterRole $name in $f" ;; esac ;;
    *) problem "unexpected standalone $kind in $f" ;;
  esac
done
crds=$(ls bundle/manifests/*.yaml | xargs -n1 "$YQ" '.kind' | grep -c CustomResourceDefinition || true)
[ "$crds" = 13 ] || problem "bundle has $crds CRDs, want 13"

[ $fail = 0 ] && echo "verify-operand-manifests: OK"
exit $fail
