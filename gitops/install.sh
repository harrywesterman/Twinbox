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

wait_for_argocd_deployments() {
  local deployment
  local deployments=()

  mapfile -t deployments < <(kubectl -n argocd get deployment -o name 2>/dev/null | sort)

  for deployment in "${deployments[@]}"; do
    log "Waiting for ${deployment} to become ready"
    kubectl -n argocd rollout status "$deployment" --timeout=600s
  done
}

log "Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

log "Installing Argo CD"
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml

wait_for_argocd_deployments

log "Applying bootstrap root application"
kubectl apply -f "$WORKSPACE_ROOT/gitops/argocd/bootstrap/root.yaml"
