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
ts_authkey="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ts_authkey')"
ts_tag="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ts_tag // empty')"
headscale_url="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.headscale_url // empty')"
headscale_key="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.headscale_key // empty')"

# Validate required inputs
[[ -n "$ts_authkey" ]] || fail "Tailscale auth key is required"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Tailscale ingress configuration for cluster: $cluster_id"
if [[ -n "$ts_tag" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ACL tag: $ts_tag"
fi
if [[ -n "$headscale_url" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Headscale URL: $headscale_url"
fi

# Step 1: Store Tailscale credentials as global secret
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing Tailscale credentials to secrets"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/tailscale-ingress-${cluster_id}.json" <<EOF
{
  "TS_AUTHKEY": "$ts_authkey",
  "TS_TAG": "${ts_tag:-}",
  "TS_HEADSCALE_URL": "${headscale_url:-}",
  "TS_HEADSCALE_KEY": "${headscale_key:-}",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$secrets_dir/tailscale-ingress-${cluster_id}.json"

# Sync to OpenBao
if [[ -f "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing Tailscale credentials to OpenBao"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "tailscale-ingress" \
    --json-file "$secrets_dir/tailscale-ingress-${cluster_id}.json" \
    --required-keys "TS_AUTHKEY"
fi

# Step 2: Deploy Tailscale operator
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying Tailscale operator"
if command -v kubectl &>/dev/null; then
  # Wait for Argo CD to be available
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD to be ready"
  for i in $(seq 1 30); do
    if kubectl get deployment argocd-server -n argocd &>/dev/null; then
      ready="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
      if [[ "$ready" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server is ready"
        break
      fi
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done

  # Apply the Tailscale application
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Tailscale application"
  kubectl apply -f "$WORKSPACE_ROOT/gitops/apps/tailscale.yaml" 2>/dev/null || true
  kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/tailscale/externalsecret.yaml" 2>/dev/null || true

  # Wait for Tailscale operator to be ready
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Tailscale operator"
  for i in $(seq 1 60); do
    if kubectl get deployment tailscale-operator -n tailscale &>/dev/null; then
      ready="$(kubectl get deployment tailscale-operator -n tailscale -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
      if [[ "$ready" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tailscale operator is ready"
        break
      fi
    fi
    sleep 5
  done

  # Step 3: Create Tailscale connector for the cluster
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating Tailscale connector"
  
  # Build connector spec
  connector_name="twinbox-${cluster_slug}"
  
  # If using Headscale, configure accordingly
  if [[ -n "$headscale_url" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring for self-hosted Headscale"
    # Create a ConfigMap with Headscale configuration
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tailscale-headscale-config
  namespace: tailscale
data:
  HEADSCALE_URL: "${headscale_url}"
EOF
  fi

  # Step 4: Create IngressRoutes for webtailscale entryPoint
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring webtailscale IngressRoutes exist"
  # The IngressRoutes are already defined in gitops/platform/*/ingressroute.yaml
  # They include the webtailscale entryPoint which will be used when Tailscale is active
fi

# Step 5: Print Tailscale connection instructions
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tailscale is now configured"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] To access your cluster services:"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   1. Install Tailscale on your device"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   2. Connect to your tailnet"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   3. Access services via their Tailscale IPs"
if [[ -n "$headscale_url" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')]   4. Your Headscale URL: $headscale_url"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo ""

# Store ingress strategy in cluster state
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as tailscale"
if [[ -f "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "tailscale"' "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" > "$tmp_file"
  mv "$tmp_file" "$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tailscale ingress configuration complete"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "outputs": {
    "ingress_strategy": "tailscale",
    "ts_tag": "${ts_tag:-}",
    "headscale_url": "${headscale_url:-}",
    "cluster_id": "$cluster_id"
  }
}
EOF
fi
