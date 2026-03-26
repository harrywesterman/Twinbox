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

wait_for_argocd_workloads() {
  local selector
  local selectors=(
    "app.kubernetes.io/name=argocd-applicationset-controller"
    "app.kubernetes.io/name=argocd-dex-server"
    "app.kubernetes.io/name=argocd-redis"
    "app.kubernetes.io/name=argocd-repo-server"
    "app.kubernetes.io/name=argocd-server"
  )

  for selector in "${selectors[@]}"; do
    log "Waiting for pods with selector ${selector} to become ready"
    kubectl -n argocd wait --for=condition=Ready pod -l "$selector" --timeout=600s
  done

  log "Waiting for statefulset/argocd-application-controller pod to become ready"
  kubectl -n argocd wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-application-controller --timeout=600s
}

log "Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

log "Installing Argo CD"
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml

patch_argocd_workload_tolerations

wait_for_argocd_workloads

log "Applying bootstrap root application"
kubectl apply -f "$WORKSPACE_ROOT/gitops/argocd/bootstrap/root.yaml"
