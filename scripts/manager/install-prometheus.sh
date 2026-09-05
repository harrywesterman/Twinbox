#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
export KUBECONFIG="$KUBECONFIG_FILE"

metrics_server_manifest_path="$WORKSPACE_ROOT/gitops/apps/metrics-server.yaml"
observability_profile="${TWINBOX_OBSERVABILITY_PROFILE:-full}"
case "$observability_profile" in
  minimal)
    manifest_path="$WORKSPACE_ROOT/gitops/apps/prometheus-minimal.yaml"
    ;;
  full|off|"")
    manifest_path="$WORKSPACE_ROOT/gitops/apps/prometheus.yaml"
    ;;
  *)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Unsupported TWINBOX_OBSERVABILITY_PROFILE=${observability_profile}" >&2
    exit 1
    ;;
esac
rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/prometheus-application-XXXXXX")"
trap 'rm -f "$rendered_manifest"' EXIT

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_slug" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine cluster slug from STEP_CONTEXT_JSON" >&2
  exit 1
}
[[ -n "$cluster_dns_domain" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine cluster DNS domain from STEP_CONTEXT_JSON" >&2
  exit 1
}

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine public zone name" >&2
  exit 1
}

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$metrics_server_manifest_path" \
  --application "metrics-server" \
  --skip-namespace-baseline

sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$rendered_manifest"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_manifest" \
  --application "prometheus" \
  --destination-namespace "monitoring"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "prometheus" \
  --service-domain "prometheus.${public_zone_name}" \
  --service-path /
TWINBOX_CLUSTER_ID="$(jq -r '.cluster.id' <<<"$STEP_CONTEXT_JSON")" bash "$WORKSPACE_ROOT/scripts/manager/register-backup-vm-monitoring.sh"
