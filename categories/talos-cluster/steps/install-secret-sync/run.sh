#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"

operator_namespace="external-secrets"
bitwarden_namespace="bitwarden"
target_namespace="twinbox-system"
login_store_name="bitwarden-login"
fields_store_name="bitwarden-fields"
external_secret_name="proxmox-bootstrap"
target_secret_name="proxmox-bootstrap"

bash scripts/manager/install-secret-sync.sh \
  --cluster-id "$cluster_id" \
  --operator-namespace "$operator_namespace" \
  --bitwarden-namespace "$bitwarden_namespace" \
  --target-namespace "$target_namespace" \
  --login-store-name "$login_store_name" \
  --fields-store-name "$fields_store_name" \
  --external-secret-name "$external_secret_name" \
  --target-secret-name "$target_secret_name"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg operator_namespace "$operator_namespace" \
    --arg bitwarden_namespace "$bitwarden_namespace" \
    --arg target_namespace "$target_namespace" \
    --arg login_store_name "$login_store_name" \
    --arg fields_store_name "$fields_store_name" \
    --arg external_secret_name "$external_secret_name" \
    --arg target_secret_name "$target_secret_name" \
    '{
      cluster_id: $cluster_id,
      operator_namespace: $operator_namespace,
      bitwarden_namespace: $bitwarden_namespace,
      target_namespace: $target_namespace,
      secret_store_names: [$login_store_name, $fields_store_name],
      synced_secret_names: [$external_secret_name, $target_secret_name]
    }' >"$STEP_RESULT_FILE"
fi
