#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_instance_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')"

operator_namespace="external-secrets"
openbao_namespace="openbao"
target_namespace="twinbox-system"
cluster_secret_store_name="openbao"
external_secret_name="proxmox-bootstrap"
target_secret_name="proxmox-bootstrap"

bash "$WORKSPACE_ROOT/scripts/manager/install-secret-sync.sh" \
  --cluster-id "$cluster_id" \
  --operator-namespace "$operator_namespace" \
  --openbao-namespace "$openbao_namespace" \
  --target-namespace "$target_namespace" \
  --cluster-secret-store-name "$cluster_secret_store_name" \
  --external-secret-name "$external_secret_name" \
  --target-secret-name "$target_secret_name"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$cluster_instance_id" \
    --arg operator_namespace "$operator_namespace" \
    --arg openbao_namespace "$openbao_namespace" \
    --arg target_namespace "$target_namespace" \
    --arg cluster_secret_store_name "$cluster_secret_store_name" \
    --arg external_secret_name "$external_secret_name" \
    --arg target_secret_name "$target_secret_name" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      operator_namespace: $operator_namespace,
      openbao_namespace: $openbao_namespace,
      target_namespace: $target_namespace,
      cluster_secret_store_name: $cluster_secret_store_name,
      synced_secret_names: [$external_secret_name, $target_secret_name]
    }' >"$STEP_RESULT_FILE"
fi
