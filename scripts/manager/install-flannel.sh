#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_daemonset_rollout() {
  local namespace="$1"
  local daemonset="$2"

  log "Waiting for daemonset/${daemonset} rollout in namespace/${namespace}"
  kubectl -n "$namespace" rollout status "daemonset/${daemonset}" --timeout=900s
}

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

export KUBECONFIG="$KUBECONFIG_FILE"

log "Bootstrapping Flannel before Argo CD so the cluster has pod networking"
kubectl apply -k "$WORKSPACE_ROOT/gitops/platform/flannel"
wait_for_daemonset_rollout "kube-flannel" "kube-flannel-ds"
