#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
controlplane_ip="$(printf '%s' "$cluster_json" | jq -r '(.discovered_controlplane_ips[0] // .controlplane_ips[0] // empty)')"

[[ -n "$controlplane_ip" ]] || {
  echo "Missing controlplane IP for cluster ${cluster_id}" >&2
  exit 1
}

bash "$WORKSPACE_ROOT/scripts/manager/install-argocd.sh" --kube-api-server "https://${controlplane_ip}:6443"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg root_application "root" \
    --argjson root_applications '["traefik","routes"]' \
    '{
      cluster_id: $cluster_id,
      root_application: $root_application,
      root_applications: $root_applications
    }' >"$STEP_RESULT_FILE"
fi
