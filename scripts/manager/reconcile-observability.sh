#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
profile="${OBSERVABILITY_PROFILE:-${TWINBOX_OBSERVABILITY_PROFILE:-full}}"
profile="$(printf '%s' "$profile" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from STEP_CONTEXT_JSON"
[[ -n "$cluster_slug" ]] || fail "Could not determine cluster slug from STEP_CONTEXT_JSON"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain from STEP_CONTEXT_JSON"

apply_full_stack() {
  log "Applying full observability stack"
  bash "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-prometheus/run.sh"
  bash "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-loki/run.sh"
  bash "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-tempo/run.sh"
  bash "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-alloy/run.sh"
  bash "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-grafana/run.sh"
}

apply_minimal_stack() {
  log "Applying minimal observability stack"
  TWINBOX_OBSERVABILITY_PROFILE=minimal bash "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-prometheus/run.sh"
  remove_full_stack_components
}

remove_observability_app() {
  local app_name="$1"
  local manifest_path="$2"

  APP_NAME="$app_name" MANIFEST_PATH="$manifest_path" \
    bash "$WORKSPACE_ROOT/scripts/manager/uninstall-argocd-application.sh"
}

remove_full_stack_components() {
  log "Removing Grafana, Loki, Tempo, and Alloy"
  remove_observability_app "grafana" "$WORKSPACE_ROOT/gitops/apps/grafana.yaml"
  remove_observability_app "loki" "$WORKSPACE_ROOT/gitops/apps/loki.yaml"
  remove_observability_app "tempo" "$WORKSPACE_ROOT/gitops/apps/tempo.yaml"
  remove_observability_app "alloy" "$WORKSPACE_ROOT/gitops/apps/alloy.yaml"
}

delete_monitoring_pvcs() {
  log "Deleting monitoring namespace PVCs"
  kubectl -n monitoring delete pvc --all --ignore-not-found=true >/dev/null 2>&1 || true
}

remove_complete_stack() {
  log "Removing full observability stack"
  remove_full_stack_components
  remove_observability_app "prometheus" "$WORKSPACE_ROOT/gitops/apps/prometheus.yaml"
  delete_monitoring_pvcs
}

case "$profile" in
  full)
    apply_full_stack
    ;;
  minimal)
    apply_minimal_stack
    delete_monitoring_pvcs
    ;;
  off)
    remove_complete_stack
    ;;
  *)
    fail "Unsupported observability profile: ${profile}"
    ;;
esac

log "Observability profile ${profile} reconciled for cluster ${cluster_id}"
