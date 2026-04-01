#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# Parse cluster context
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

# Parse inputs
wiredoor_url="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.wiredoor_url')"
wiredoor_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.wiredoor_token')"
wiredoor_node_name="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.wiredoor_node_name // empty')"

# Validate required inputs
[[ -n "$wiredoor_url" ]] || fail "Wiredoor server URL is required"
[[ -n "$wiredoor_token" ]] || fail "Wiredoor API token is required"

# Default node name to cluster slug if not provided
if [[ -z "$wiredoor_node_name" ]]; then
  wiredoor_node_name="$cluster_slug"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Wiredoor ingress configuration for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor URL: $wiredoor_url"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Node name: $wiredoor_node_name"

# Store Wiredoor credentials as a global secret
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing Wiredoor credentials to secrets"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/wiredoor-ingress-${cluster_id}.json" <<EOF
{
  "WIREDOOR_URL": "$wiredoor_url",
  "WIREDOOR_TOKEN": "$wiredoor_token",
  "WIREDOOR_NODE_NAME": "$wiredoor_node_name",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$secrets_dir/wiredoor-ingress-${cluster_id}.json"

# Sync to OpenBao
if [[ -f "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing Wiredoor credentials to OpenBao"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "wiredoor-ingress" \
    --json-file "$secrets_dir/wiredoor-ingress-${cluster_id}.json" \
    --required-keys "WIREDOOR_URL,WIREDOOR_TOKEN"
fi

# Apply Wiredoor gateway Argo CD application
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring Wiredoor gateway application is deployed"
if command -v kubectl &>/dev/null; then
  # Wait for Argo CD to be available
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD to be ready"
  for i in $(seq 1 30); do
    if kubectl get application argocd -n argocd &>/dev/null; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD is ready"
      break
    fi
    sleep 5
  done

  # Sync the wiredoor-gateway application
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing wiredoor-gateway application"
  kubectl apply -f "$WORKSPACE_ROOT/gitops/apps/wiredoor-gateway.yaml" 2>/dev/null || true
  kubectl apply -f "$WORKSPACE_ROOT/gitops/apps/wiredoor-gateway-secret/externalsecret.yaml" 2>/dev/null || true
fi

# Store ingress strategy in cluster state
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as wiredoor"
if [[ -f "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "wiredoor"' "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" > "$tmp_file"
  mv "$tmp_file" "$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor ingress configuration complete"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "outputs": {
    "ingress_strategy": "wiredoor",
    "wiredoor_url": "$wiredoor_url",
    "wiredoor_node_name": "$wiredoor_node_name",
    "cluster_id": "$cluster_id"
  }
}
EOF
fi
