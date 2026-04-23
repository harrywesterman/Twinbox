#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [--kube-api-server URL]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBE_API_SERVER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --kube-api-server)
      KUBE_API_SERVER="$2"
      shift 2
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${KUBECONFIG_FILE:-}" ]] || { usage; fail "KUBECONFIG_FILE is required"; }
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

require_cmd kubectl
require_cmd jq

export KUBECONFIG="$KUBECONFIG_FILE"

if [[ -n "$KUBE_API_SERVER" ]]; then
  kube_cluster_name="$(kubectl config view --kubeconfig "$KUBECONFIG_FILE" -o jsonpath='{.clusters[0].name}')"
  [[ -n "$kube_cluster_name" ]] || fail "Unable to read cluster name from kubeconfig"
  log "Rewriting kubeconfig cluster ${kube_cluster_name} to ${KUBE_API_SERVER}"
  kubectl config set-cluster "$kube_cluster_name" --kubeconfig "$KUBECONFIG_FILE" --server "$KUBE_API_SERVER" >/dev/null
fi

log "Bootstrapping Argo CD"
bash "$WORKSPACE_ROOT/gitops/install.sh"

log "Applying Argo CD Image Updater application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/argocd-image-updater.yaml" \
  --application "argocd-image-updater" \
  --destination-namespace "argocd"
