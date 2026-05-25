#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_instance_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')"
controlplane_ip="$(printf '%s' "$cluster_json" | jq -r '(.discovered_controlplane_ips[0] // .controlplane_ips[0] // empty)')"

[[ -n "$controlplane_ip" ]] || {
  echo "Missing controlplane IP for cluster ${cluster_id}" >&2
  exit 1
}

bash "$WORKSPACE_ROOT/scripts/manager/install-argocd.sh" --kube-api-server "https://${controlplane_ip}:6443"

# Source for zone lookup
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
cluster_dns_domain="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.dns_domain // empty')"
cluster_slug="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.slug // .cluster.id // empty')"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "argocd" \
  --service-domain "argocd.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$cluster_instance_id" \
    --arg application "argocd" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application
    }' >"$STEP_RESULT_FILE"
fi
