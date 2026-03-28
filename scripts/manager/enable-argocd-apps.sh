#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID --enabled-apps CSV --applications CSV
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

split_csv() {
  local value="${1:-}"
  local -n out_ref="$2"

  out_ref=()
  value="${value// /}"
  [[ -n "$value" ]] || return 0
  IFS=',' read -r -a out_ref <<< "$value"
}

wait_for_application_ready() {
  local application="$1"
  local status_json=""
  local sync_status=""
  local health_status=""
  local operation_phase=""
  local attempt=1
  local attempts=180

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

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -n "${MANAGER_DATA_DIR:-}" ]] || fail "MANAGER_DATA_DIR is required"
[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"

CLUSTER_ID=""
ENABLED_APPS_CSV=""
APPLICATIONS_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --enabled-apps) ENABLED_APPS_CSV="$2"; shift 2 ;;
    --applications) APPLICATIONS_CSV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$CLUSTER_ID" ]] || { usage; fail "cluster-id required"; }
[[ -n "$ENABLED_APPS_CSV" ]] || { usage; fail "enabled-apps required"; }
[[ -n "$APPLICATIONS_CSV" ]] || { usage; fail "applications required"; }

cluster_file="$MANAGER_DATA_DIR/clusters/${CLUSTER_ID}.json"
[[ -f "$cluster_file" ]] || fail "cluster not found: ${CLUSTER_ID}"

declare -a enabled_apps applications
split_csv "$ENABLED_APPS_CSV" enabled_apps
split_csv "$APPLICATIONS_CSV" applications

declare -A manifest_paths=(
  [whoami]="$WORKSPACE_ROOT/gitops/argocd/optional/apps/whoami.yaml"
  [whoami-routes]="$WORKSPACE_ROOT/gitops/argocd/optional/routes/whoami.yaml"
  [headlamp]="$WORKSPACE_ROOT/gitops/argocd/optional/apps/headlamp.yaml"
  [headlamp-routes]="$WORKSPACE_ROOT/gitops/argocd/optional/routes/headlamp.yaml"
  [grafana-secret]="$WORKSPACE_ROOT/gitops/argocd/optional/apps/grafana-secret.yaml"
  [grafana]="$WORKSPACE_ROOT/gitops/argocd/optional/apps/grafana.yaml"
  [grafana-routes]="$WORKSPACE_ROOT/gitops/argocd/optional/routes/grafana.yaml"
  [wiredoor-gateway-secret]="$WORKSPACE_ROOT/gitops/argocd/optional/apps/wiredoor-gateway-secret.yaml"
  [wiredoor-gateway]="$WORKSPACE_ROOT/gitops/argocd/optional/apps/wiredoor-gateway.yaml"
  [wiredoor-gateway-routes]="$WORKSPACE_ROOT/gitops/argocd/optional/routes/wiredoor-gateway.yaml"
)

for application in "${applications[@]}"; do
  [[ -n "$application" ]] || continue
  [[ -n "${manifest_paths[$application]:-}" ]] || fail "Unknown optional application: ${application}"
  [[ -f "${manifest_paths[$application]}" ]] || fail "Application manifest not found: ${manifest_paths[$application]}"
done

for application in "${applications[@]}"; do
  [[ -n "$application" ]] || continue
  log "Applying optional Argo application ${application}"
  kubectl apply --validate=false -f "${manifest_paths[$application]}"
done

for application in "${applications[@]}"; do
  [[ -n "$application" ]] || continue
  wait_for_application_ready "$application"
done

enabled_apps_json="$(printf '%s\n' "${enabled_apps[@]}" | jq -R . | jq -s .)"
tmp="$(mktemp)"
jq \
  --argjson enabled_apps "$enabled_apps_json" \
  '
    .enabled_optional_apps = (
      (.enabled_optional_apps // []) as $existing
      | reduce $enabled_apps[] as $app ($existing; if index($app) == null then . + [$app] else . end)
    )
  ' \
  "$cluster_file" > "$tmp"
mv "$tmp" "$cluster_file"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$CLUSTER_ID" \
    --argjson enabled_optional_apps "$enabled_apps_json" \
    --argjson applications "$(printf '%s\n' "${applications[@]}" | jq -R . | jq -s .)" \
    '{
      cluster_id: $cluster_id,
      enabled_optional_apps: $enabled_optional_apps,
      applications: $applications
    }' >"$STEP_RESULT_FILE"
fi
