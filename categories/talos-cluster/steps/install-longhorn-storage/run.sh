#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
application_name="longhorn"
chart_version="1.11.1"
application_manifest="$WORKSPACE_ROOT/gitops/longhorn/application.yaml"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq not found" >&2
  exit 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

wait_for_application_ready() {
  local application="$1"
  local status_json=""
  local sync_status=""
  local health_status=""
  local operation_phase=""
  local attempt=1
  local attempts=240

  while true; do
    if status_json="$(kubectl -n argocd get application "$application" -o json 2>/dev/null)"; then
      sync_status="$(jq -r '.status.sync.status // "Unknown"' <<<"$status_json")"
      health_status="$(jq -r '.status.health.status // "Unknown"' <<<"$status_json")"
      operation_phase="$(jq -r '.status.operationState.phase // "Unknown"' <<<"$status_json")"
      log "Waiting for application/${application}: sync=${sync_status}, health=${health_status}, phase=${operation_phase}"

      if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$operation_phase" != "Running" && "$operation_phase" != "Terminating" ]]; then
        log "Application/${application} is Synced and Healthy"
        return 0
      fi
    else
      log "Waiting for application/${application} to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      return 1
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

log "Applying Longhorn application manifest"
kubectl apply --server-side --force-conflicts --validate=false -f "$application_manifest"

log "Waiting for Longhorn application to report healthy"
wait_for_application_ready "$application_name"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg application_name "$application_name" \
    --arg chart_version "$chart_version" \
    --arg manifest_path "$application_manifest" \
    '{
      cluster_id: $cluster_id,
      application_name: $application_name,
      chart_version: $chart_version,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
