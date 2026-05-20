#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_id="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.id')"
[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing AdGuard Home for cluster: $cluster_id"

if command -v kubectl >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD server"
  for i in $(seq 1 30); do
    ready="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    if [[ "${ready:-0}" -gt 0 ]]; then
      break
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done

  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$WORKSPACE_ROOT/gitops/apps/adguard.yaml" \
    --application "adguard" \
    --destination-namespace "argocd"
else
  fail "kubectl is required to install AdGuard Home"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for AdGuard DaemonSet to be ready..."
for i in $(seq 1 60); do
  ready="$(kubectl get daemonset adguard -n adguard -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")"
  desired="$(kubectl get daemonset adguard -n adguard -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")"
  if [[ "${ready:-0}" -gt 0 && "$ready" -eq "$desired" && "$desired" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DaemonSet is ready (${ready}/${desired} pods)"
    break
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard not ready yet (attempt ${i}/60, ${ready:-0}/${desired:-0} pods)"
  sleep 5
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard Home is installed and ready"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg cluster_id "$cluster_id" \
    '{status: $status, outputs: {cluster_id: $cluster_id, application: "adguard"}}' >"$STEP_RESULT_FILE"
fi
