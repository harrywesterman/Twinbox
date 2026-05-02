#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${KUBECONFIG_FILE:-}" && -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG="$KUBECONFIG_FILE"
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl not found" >&2
  exit 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

# shellcheck source=../config/pinned-defaults.sh
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"
[[ -n "${PINNED_ARGOCD_VERSION:-}" ]] || fail "Missing required variable in ${WORKSPACE_ROOT}/config/pinned-defaults.sh: PINNED_ARGOCD_VERSION"
ARGOCD_VERSION="${PINNED_ARGOCD_VERSION#v}"
retry() {
  local attempts="$1"
  local delay_seconds="$2"
  shift 2

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      return 1
    fi

    log "Retrying ${*} in ${delay_seconds}s (${attempt}/${attempts})"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

control_plane_tolerations='[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]'

patch_argocd_workload_tolerations() {
  local resource
  local patch

  patch=$(cat <<EOF
{"spec":{"template":{"spec":{"tolerations":${control_plane_tolerations}}}}}
EOF
  )

  for resource in $(kubectl -n argocd get deployment -o name 2>/dev/null | sort); do
    log "Patching ${resource} for control-plane tolerations"
    kubectl -n argocd patch "$resource" --type merge -p "$patch"
  done

  for resource in $(kubectl -n argocd get statefulset -o name 2>/dev/null | sort); do
    log "Patching ${resource} for control-plane tolerations"
    kubectl -n argocd patch "$resource" --type merge -p "$patch"
  done
}

patch_argocd_workload_probes() {
  local resource
  local container_name
  local patch

  for resource in deployment/argocd-repo-server deployment/argocd-server; do
    case "$resource" in
      deployment/argocd-repo-server)
        container_name="argocd-repo-server"
        ;;
      deployment/argocd-server)
        container_name="argocd-server"
        ;;
      *)
        fail "Unexpected Argo CD resource: ${resource}"
        ;;
    esac

    patch=$(cat <<EOF
{"spec":{"template":{"spec":{"containers":[{"name":"${container_name}","livenessProbe":{"initialDelaySeconds":300,"timeoutSeconds":5,"periodSeconds":30,"failureThreshold":10}}]}}}}
EOF
    )

    log "Patching ${resource} liveness probe for single-node bootstrap"
    kubectl -n argocd patch "$resource" --type strategic -p "$patch"
  done
}

patch_argocd_repo_server_copyutil() {
  local patch

  patch=$(cat <<'EOF'
{"spec":{"template":{"spec":{"initContainers":[{"name":"copyutil","args":["/bin/cp --update=none /usr/local/bin/argocd /var/run/argocd/argocd && /bin/ln -sfn /var/run/argocd/argocd /var/run/argocd/argocd-cmp-server"]}]}}}}
EOF
  )

  for resource in $(kubectl -n argocd get deployment -o name 2>/dev/null | grep -E '(^|/)argocd-repo-server($|-)' || true); do
    log "Patching ${resource} copyutil init container for idempotent startup"
    kubectl -n argocd patch "$resource" --type strategic -p "$patch"
  done
}

wait_for_available() {
  local resource="$1"

  log "Waiting for ${resource} to become available"
  kubectl -n argocd wait --for=condition=Available "$resource" --timeout=900s
}

wait_for_statefulset_rollout() {
  local resource="$1"

  log "Waiting for ${resource} rollout to become ready"
  kubectl -n argocd rollout status "$resource" --timeout=900s
}

wait_for_argocd_workloads() {
  local resource

  for resource in $(kubectl -n argocd get deployment -o name 2>/dev/null | sort); do
    wait_for_available "$resource"
  done

  for resource in $(kubectl -n argocd get statefulset -o name 2>/dev/null | sort); do
    wait_for_statefulset_rollout "$resource"
  done
}

log "Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -

log "Installing Argo CD v${ARGOCD_VERSION}"
retry 3 10 kubectl apply --server-side --force-conflicts --validate=false -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/ha/install.yaml"

patch_argocd_workload_tolerations
patch_argocd_workload_probes
patch_argocd_repo_server_copyutil

wait_for_argocd_workloads
