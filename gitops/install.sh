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

  if kubectl -n argocd get statefulset/argocd-application-controller >/dev/null 2>&1; then
    log "Patching statefulset/argocd-application-controller for control-plane tolerations"
    kubectl -n argocd patch statefulset/argocd-application-controller --type merge -p "$patch"
  fi
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

  log "Patching deployment/argocd-repo-server copyutil init container for idempotent startup"
  kubectl -n argocd patch deployment/argocd-repo-server --type strategic -p "$patch"
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
  local resources=(
    "deployment/argocd-applicationset-controller"
    "deployment/argocd-dex-server"
    "deployment/argocd-notifications-controller"
    "deployment/argocd-redis"
    "deployment/argocd-repo-server"
    "deployment/argocd-server"
  )

  for resource in "${resources[@]}"; do
    wait_for_available "$resource"
  done

  wait_for_statefulset_rollout "statefulset/argocd-application-controller"
}

log "Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -

log "Installing Argo CD"
retry 3 10 kubectl apply --server-side --force-conflicts --validate=false -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml

patch_argocd_workload_tolerations
patch_argocd_workload_probes
patch_argocd_repo_server_copyutil

wait_for_argocd_workloads

log "Applying full Argo root application"
retry 3 10 kubectl apply --validate=false -f "$WORKSPACE_ROOT/gitops/argocd/root.yaml"
