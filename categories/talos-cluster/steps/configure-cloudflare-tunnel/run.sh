#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_slug_lower="$(printf '%s' "$cluster_slug" | tr '[:upper:]' '[:lower:]')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
if [[ "$cluster_slug_lower" != "prd" ]]; then
  fail "Cloudflare Tunnel is only available for prd clusters on Cloudflare Free"
fi

# Parse inputs
cf_api_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cf_api_token')"
cf_account_id="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cf_account_id')"
cf_zone_id="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.cf_zone_id')"

# Validate required inputs
[[ -n "$cf_api_token" ]] || fail "Cloudflare API token is required"
[[ -n "$cf_account_id" ]] || fail "Cloudflare account ID is required"
[[ -n "$cf_zone_id" ]] || fail "Cloudflare zone ID is required"
[[ -n "$cluster_dns_domain" ]] || fail "DNS domain is required from the ingress selection step"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"
cloudflare_dns_zone_name="$(twinbox_cluster_dns_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$cloudflare_dns_zone_name" ]] || fail "Could not determine Cloudflare DNS zone name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Cloudflare Tunnel configuration for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account ID: $cf_account_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Zone ID: $cf_zone_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS zone name: $cloudflare_dns_zone_name"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public zone name: $public_zone_name"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Using the provided Cloudflare token for DNS record creation"

# Step 1: Create Cloudflare Tunnel
tunnel_name="twinbox-${cluster_id}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating tunnel: $tunnel_name"

tunnel_response="$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${tunnel_name}\",\"config_src\":\"local\"}")"

tunnel_success="$(echo "$tunnel_response" | jq -r '.success')"
if [[ "$tunnel_success" != "true" ]]; then
  # Check if tunnel already exists
  tunnel_exists="$(echo "$tunnel_response" | jq -r '.errors[0].message // ""')"
  if [[ "$tunnel_exists" == *"already exists"* || "$tunnel_exists" == *"already have a tunnel with this name"* ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tunnel already exists, fetching existing tunnel"
    tunnels_list="$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel?name=${tunnel_name}" \
      -H "Authorization: Bearer $cf_api_token" \
      -H "Content-Type: application/json")"
    cf_tunnel_id="$(echo "$tunnels_list" | jq -r '.result[0].id // empty')"
  else
    error_msg="$(echo "$tunnel_response" | jq -r '.errors[0].message // "Unknown error"')"
    fail "Failed to create Cloudflare tunnel: $error_msg"
  fi
else
  cf_tunnel_id="$(echo "$tunnel_response" | jq -r '.result.id')"
fi

[[ -n "$cf_tunnel_id" ]] || fail "Could not determine tunnel ID"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tunnel ID: $cf_tunnel_id"

# Step 2: Generate tunnel token
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Generating tunnel token"
token_response="$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel/${cf_tunnel_id}/token" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json")"

token_success="$(echo "$token_response" | jq -r '.success // false')"
if [[ "$token_success" != "true" ]]; then
  token_error="$(echo "$token_response" | jq -r '.errors[0].message // "Unknown error"')"
  fail "Could not generate tunnel token: $token_error"
fi

cf_tunnel_token="$(echo "$token_response" | jq -r '.result // empty')"
[[ -n "$cf_tunnel_token" ]] || fail "Could not generate tunnel token"

# Step 3: Publish the public hostnames in the tunnel config so Cloudflare can
# forward the wildcard domain to Traefik inside the cluster.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Publishing tunnel ingress routes"
tunnel_service_url="https://traefik.traefik.svc.cluster.local:443"
tunnel_config_payload="$(jq -nc \
  --arg hostname "*.${public_zone_name}" \
  --arg tunnel_service_url "$tunnel_service_url" \
  '{
    config: {
      ingress: [
        {hostname: $hostname, service: $tunnel_service_url, originRequest: {noTLSVerify: true}},
        {service: "http_status:404"}
      ]
    }
  }')"

tunnel_config_response="$(curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${cf_account_id}/cfd_tunnel/${cf_tunnel_id}/configurations" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json" \
  -d "$tunnel_config_payload")"

tunnel_config_success="$(echo "$tunnel_config_response" | jq -r '.success // false')"
if [[ "$tunnel_config_success" != "true" ]]; then
  tunnel_config_error="$(echo "$tunnel_config_response" | jq -r '.errors[0].message // "Unknown error"')"
  fail "Could not publish tunnel ingress routes: $tunnel_config_error"
fi

# Step 4: Preflight the Cloudflare zone before writing DNS records
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Preflighting Cloudflare zone"
zone_response="$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}" \
  -H "Authorization: Bearer $cf_api_token" \
  -H "Content-Type: application/json")"

zone_success="$(echo "$zone_response" | jq -r '.success // false')"
if [[ "$zone_success" != "true" ]]; then
  zone_error="$(echo "$zone_response" | jq -r '.errors[0].message // "Unknown error"')"
  if [[ "$zone_error" == *"Unauthorized to access requested resource"* ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Cloudflare token cannot read zone metadata for ${cf_zone_id}; continuing without a zone-name preflight"
  else
    fail "Could not read Cloudflare zone ${cf_zone_id}: $zone_error"
  fi
else
  cloudflare_zone_name="$(echo "$zone_response" | jq -r '.result.name // empty')"
  [[ -n "$cloudflare_zone_name" ]] || fail "Cloudflare zone lookup returned no zone name for ${cf_zone_id}"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cloudflare sees zone name: $cloudflare_zone_name"
  if [[ "$cloudflare_zone_name" != "$cloudflare_dns_zone_name" ]]; then
    fail "Cloudflare zone ${cf_zone_id} resolves to ${cloudflare_zone_name}, but the wizard selected ${cloudflare_dns_zone_name}"
  fi
fi

cloudflare_tunnel_manifest="$MANAGER_DATA_DIR/tmp/cloudflare-tunnel-${cluster_id}.yaml"
mkdir -p "$(dirname "$cloudflare_tunnel_manifest")"
cat > "$cloudflare_tunnel_manifest" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflare-tunnel
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://cloudflare.github.io/helm-charts
    chart: cloudflare-tunnel-remote
    targetRevision: "0.1.2"
    helm:
      values: |
        cloudflare:
          tunnel_token: "$cf_tunnel_token"

        replicaCount: 2

        tolerations:
          - key: node-role.kubernetes.io/control-plane
            operator: Exists
            effect: NoSchedule
          - key: node-role.kubernetes.io/master
            operator: Exists
            effect: NoSchedule

        metrics:
          enabled: true
          serviceMonitor:
            enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudflare-tunnel
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/warn: privileged
    syncOptions:
      - CreateNamespace=true
EOF
trap 'rm -f "$cloudflare_tunnel_manifest"' EXIT
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rendered cloudflare-tunnel application to $cloudflare_tunnel_manifest"

# Step 4: Create DNS CNAME record via external-dns DNSEndpoint
dns_record_name="*.${public_zone_name}"
dns_record_content="${cf_tunnel_id}.cfargotunnel.com"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating DNSEndpoint for tunnel CNAME: ${dns_record_name} -> ${dns_record_content}"

kubectl apply -f - <<EOF
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: cloudflare-tunnel-dns
  namespace: external-dns
spec:
  endpoints:
    - dnsName: "${dns_record_name}"
      recordType: CNAME
      targets:
        - "${dns_record_content}"
      recordTTL: 300
EOF

# Step 5: Store credentials as global secret
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing Cloudflare Tunnel credentials to secrets"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/cloudflare-tunnel-${cluster_id}.json" <<EOF
{
  "CF_API_TOKEN": "$cf_api_token",
  "CF_ACCOUNT_ID": "$cf_account_id",
  "CF_ZONE_ID": "$cf_zone_id",
  "CF_TUNNEL_ID": "$cf_tunnel_id",
  "CF_TUNNEL_TOKEN": "$cf_tunnel_token",
  "CF_TUNNEL_NAME": "$tunnel_name",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$secrets_dir/cloudflare-tunnel-${cluster_id}.json"

# Sync to OpenBao
if [[ -f "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing Cloudflare Tunnel credentials to OpenBao"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "cloudflare-tunnel" \
    --json-file "$secrets_dir/cloudflare-tunnel-${cluster_id}.json" \
    --required-keys "CF_API_TOKEN,CF_ACCOUNT_ID,CF_ZONE_ID,CF_TUNNEL_ID,CF_TUNNEL_TOKEN"
fi

cluster_hosts_secret="$secrets_dir/cloudflare-hostnames-${cluster_id}.json"
cat > "$cluster_hosts_secret" <<EOF
{
  "ZONE_NAME": "$public_zone_name"
}
EOF
chmod 600 "$cluster_hosts_secret"

bash "$WORKSPACE_ROOT/scripts/manager/upsert-argocd-cluster-secret.sh" \
  --public-zone-name "$public_zone_name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing cluster hostnames to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "cluster-hostnames" \
  --json-file "$cluster_hosts_secret" \
  --required-keys "ZONE_NAME"

# Step 6: Deploy cloudflared in the cluster
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying cloudflared in the cluster"
if command -v kubectl &>/dev/null; then
  # Wait for Argo CD to be available
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD to be ready"
  argo_cd_ready=false
  for i in $(seq 1 30); do
    if kubectl get deployment argocd-server -n argocd &>/dev/null; then
      ready_replicas="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
      if [[ "$ready_replicas" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server is ready"
        argo_cd_ready=true
        break
      fi
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done
  if [[ "$argo_cd_ready" != "true" ]]; then
    fail "Timed out waiting for the Argo CD server deployment to become ready"
  fi

  # Refresh the parent ingress app first, then wait for it to settle before
  # creating the runtime Cloudflare app. Deleting the Application objects can
  # briefly remove shared Argo CD config such as argocd-cm, which races the
  # follow-up cloudflare-tunnel apply.
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
    --application "platform-ingress" \
    --destination-namespace "argocd"

  # Apply the cloudflare-tunnel application last so the inline runtime values
  # remain the active desired state when Argo reconciles the deployment.
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying cloudflare-tunnel application"
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$cloudflare_tunnel_manifest" \
    --application "cloudflare-tunnel"
fi

# Store ingress strategy in cluster state
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as cloudflare-tunnel"
if [[ -f "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "cloudflare-tunnel"' "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" > "$tmp_file"
  mv "$tmp_file" "$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cloudflare Tunnel configuration complete"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "outputs": {
    "ingress_strategy": "cloudflare-tunnel",
    "cf_tunnel_id": "$cf_tunnel_id",
    "cf_tunnel_name": "$tunnel_name",
    "cluster_id": "$cluster_id"
  }
}
EOF
fi
