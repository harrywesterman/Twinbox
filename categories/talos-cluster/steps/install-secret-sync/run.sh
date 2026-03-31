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

operator_namespace="external-secrets"
openbao_namespace="openbao"
target_namespace="twinbox-system"
cluster_secret_store_name="openbao"
external_secret_name="proxmox-bootstrap"
target_secret_name="proxmox-bootstrap"

TWINBOX_CLUSTER_ID="$cluster_id" \
TWINBOX_CLUSTER_INSTANCE_ID="$cluster_instance_id" \
KUBE_API_SERVER="https://${controlplane_ip}:6443" \
  bash "$WORKSPACE_ROOT/scripts/manager/install-secret-sync.sh" \
    --cluster-id "$cluster_id" \
    --operator-namespace "$operator_namespace" \
    --openbao-namespace "$openbao_namespace" \
    --target-namespace "$target_namespace" \
    --cluster-secret-store-name "$cluster_secret_store_name" \
    --external-secret-name "$external_secret_name" \
    --target-secret-name "$target_secret_name"
