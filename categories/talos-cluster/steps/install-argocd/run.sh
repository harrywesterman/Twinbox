#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_instance_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')"
controlplane_ip="$(printf '%s' "$cluster_json" | jq -r '(.discovered_controlplane_ips[0] // .controlplane_ips[0] // empty)')"
flannel_manifest_path="$WORKSPACE_ROOT/gitops/apps/flannel.yaml"

[[ -n "$controlplane_ip" ]] || {
  echo "Missing controlplane IP for cluster ${cluster_id}" >&2
  exit 1
}

bash "$WORKSPACE_ROOT/scripts/manager/install-argocd.sh" --kube-api-server "https://${controlplane_ip}:6443"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$flannel_manifest_path" \
  --application "flannel"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$cluster_instance_id" \
    --arg adopted_application "flannel" \
    --arg manifest_path "$flannel_manifest_path" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      adopted_application: $adopted_application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
