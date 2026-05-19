#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

wait_for_argocd_server() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD server"
  for i in $(seq 1 30); do
    ready="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    if [[ "${ready:-0}" -gt 0 ]]; then
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done
  fail "Argo CD server did not become ready"
}

wait_for_netbird_routing_peer() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird routing peer deployment"
  for i in $(seq 1 60); do
    if kubectl -n netbird get deployment netbird-routing-peer >/dev/null 2>&1; then
      kubectl -n netbird rollout status deployment/netbird-routing-peer --timeout=180s
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird routing peer deployment not ready yet (attempt ${i}/60)"
    sleep 5
  done
  fail "NetBird routing peer deployment did not appear"
}

wait_for_public_oidc_discovery() {
  local issuer_url="$1"
  local discovery_url="${issuer_url%/}/.well-known/openid-configuration"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for public Authentik OIDC discovery through NetBird proxy"
  for i in $(seq 1 60); do
    if curl -fsS --connect-timeout 5 --max-time 15 "$discovery_url" >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public Authentik OIDC discovery is reachable"
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public Authentik OIDC discovery not reachable yet (attempt ${i}/60): ${discovery_url}"
    sleep 5
  done
  fail "Public Authentik OIDC discovery did not become reachable through NetBird proxy: ${discovery_url}"
}

netbird_host_resource_address() {
  local address="$1"
  if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s/32' "$address"
    return
  fi
  printf '%s' "$address"
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "${cluster_dns_domain:-}")"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

netbird_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_token // empty')"
netbird_management_url="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_management_url // empty')"
traefik_resource_address="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.traefik_resource_address // empty')"
proxy_services_json="$(printf '%s' "$STEP_INPUTS_JSON" | jq -c '.proxy_services_json // empty')"
if [[ -n "$proxy_services_json" && "$proxy_services_json" != "null" ]]; then
  proxy_services_json="$(printf '%s' "$proxy_services_json" | jq -r '.')"
fi

netbird_bastion_secret="/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json"
if [[ -z "$netbird_management_url" ]]; then
  [[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at $netbird_bastion_secret"
  netbird_management_url="$(jq -r '.NETBIRD_URL // empty' "$netbird_bastion_secret")"
fi

if [[ -z "$netbird_token" ]]; then
  if [[ -f "$netbird_bastion_secret" ]]; then
    netbird_token="$(jq -r '.NETBIRD_SETUP_TOKEN // empty' "$netbird_bastion_secret")"
  fi
fi

[[ -n "$netbird_token" ]] || fail "NetBird API token is required. Either provide it as input or ensure the bastion step generated a setup token."
[[ -n "$netbird_management_url" ]] || fail "Could not determine NetBird management URL"
[[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at $netbird_bastion_secret"
netbird_proxy_ip="$(jq -r '.NETBIRD_IP // empty' "$netbird_bastion_secret")"
[[ -n "$netbird_proxy_ip" ]] || fail "NetBird bastion secret does not contain NETBIRD_IP"

if [[ -z "$traefik_resource_address" ]]; then
  traefik_resource_address="$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -z "$traefik_resource_address" || "$traefik_resource_address" == "None" ]]; then
    traefik_resource_address="traefik.traefik.svc.cluster.local"
  fi
fi
traefik_network_resource_address="$(netbird_host_resource_address "$traefik_resource_address")"

service_cidr="$(kubectl -n kube-system get pod -l component=kube-apiserver -o json 2>/dev/null | jq -r '.items[0].spec.containers[0].command[] | select(startswith("--service-cluster-ip-range=")) | sub("^--service-cluster-ip-range="; "")' || true)"
if [[ -z "$service_cidr" ]]; then
  service_cidr="10.96.0.0/12"
fi
service_cidrs_json="$(jq -n --arg cidr "$service_cidr" '[$cidr]')"

authentik_public_url="${TWINBOX_AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
authentik_domain="${authentik_public_url#https://}"
authentik_domain="${authentik_domain#http://}"
authentik_domain="${authentik_domain%%/*}"

if [[ -n "$proxy_services_json" && "$proxy_services_json" != "null" ]]; then
  if ! printf '%s' "$proxy_services_json" | jq -e 'type == "array"' >/dev/null; then
    fail "proxy_services_json must be a JSON array"
  fi
else
  proxy_services_json="[]"
fi
proxy_services_json="$(
  jq -cn \
    --arg authentik_domain "$authentik_domain" \
    --argjson extra "$proxy_services_json" \
    '[{name: "authentik", domain: $authentik_domain, path: "/"}] + ($extra | map(select(.name != "authentik")))'
)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring Authentik OIDC application for NetBird"
authentik_ensure_token
authentik_setup_forward
export AUTHENTIK_TOKEN
authentik_api_url="${AUTHENTIK_API_BASE%/api/v3}"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"

[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

auth_workdir="$MANAGER_DATA_DIR/opentofu/authentik-netbird-${cluster_id}"
mkdir -p "$auth_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-netbird/"* "$auth_workdir/"
cd "$auth_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "authentik_api_url=$authentik_api_url" \
  -var "authentik_public_url=$authentik_public_url" \
  -var "netbird_url=$netbird_management_url" \
  -var "property_mapping_ids=$property_mapping_ids_json"

netbird_oidc_client_id="$(tofu output -raw -no-color client_id)"
netbird_oidc_client_secret="$(tofu output -raw -no-color client_secret)"
netbird_oidc_issuer="$(tofu output -raw -no-color issuer_url)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird groups, routing resources, and setup keys"
network_workdir="$MANAGER_DATA_DIR/opentofu/netbird-network-${cluster_id}"
mkdir -p "$network_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird-network/"* "$network_workdir/"
cd "$network_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "netbird_token=$netbird_token" \
  -var "netbird_management_url=$netbird_management_url" \
  -var "cluster_id=$cluster_id" \
  -var "traefik_resource_address=$traefik_network_resource_address" \
  -var "service_cidrs=${service_cidrs_json}"

k8s_setup_key="$(tofu output -raw -no-color k8s_setup_key)"
management_vm_setup_key="$(tofu output -raw -no-color management_vm_setup_key)"
admins_group_id="$(tofu output -raw -no-color admins_group_id)"
management_vm_group_id="$(tofu output -raw -no-color management_vm_group_id)"
k8s_routers_group_id="$(tofu output -raw -no-color k8s_routers_group_id)"
proxy_group_id="$(tofu output -raw -no-color proxy_group_id)"
traefik_resource_id="$(tofu output -raw -no-color traefik_resource_id)"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"
routing_secret="$secrets_dir/netbird-routing-peers-${cluster_id}.json"
admin_secret="$secrets_dir/netbird-admin-access-${cluster_id}.json"
network_secret="$secrets_dir/netbird-network-${cluster_id}.json"

jq -n \
  --arg setup_key "$k8s_setup_key" \
  --arg management_url "$netbird_management_url" \
  --arg cluster_id "$cluster_id" \
  '{NB_SETUP_KEY: $setup_key, NB_MANAGEMENT_URL: $management_url, CLUSTER_ID: $cluster_id}' >"$routing_secret"

jq -n \
  --arg setup_key "$management_vm_setup_key" \
  --arg management_url "$netbird_management_url" \
  --arg cluster_id "$cluster_id" \
  '{NB_SETUP_KEY: $setup_key, NB_MANAGEMENT_URL: $management_url, CLUSTER_ID: $cluster_id}' >"$admin_secret"

chmod 600 "$routing_secret" "$admin_secret"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "netbird-routing-peers" \
  --json-file "$routing_secret" \
  --required-keys "NB_SETUP_KEY,NB_MANAGEMENT_URL"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "netbird-admin-access" \
  --json-file "$admin_secret" \
  --required-keys "NB_SETUP_KEY,NB_MANAGEMENT_URL"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying NetBird routing peers before enabling reverse proxy"
wait_for_argocd_server
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/netbird-routing-peers.yaml" \
  --application "netbird-routing-peers" \
  --destination-namespace "argocd"
wait_for_netbird_routing_peer

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird reverse proxy services"
proxy_services_workdir="$MANAGER_DATA_DIR/opentofu/netbird-proxy-services-${cluster_id}"
mkdir -p "$proxy_services_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird-proxy-services/"* "$proxy_services_workdir/"
cd "$proxy_services_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "netbird_token=$netbird_token" \
  -var "netbird_management_url=$netbird_management_url" \
  -var "traefik_resource_id=$traefik_resource_id" \
  -var "traefik_resource_address=$traefik_resource_address" \
  -var "services=$proxy_services_json"
proxy_service_ids="$(tofu output -json -no-color service_ids)"

jq -n \
  --arg management_url "$netbird_management_url" \
  --arg traefik_address "$traefik_resource_address" \
  --arg traefik_network_resource_address "$traefik_network_resource_address" \
  --arg traefik_resource_id "$traefik_resource_id" \
  --arg admins_group_id "$admins_group_id" \
  --arg management_vm_group_id "$management_vm_group_id" \
  --arg k8s_routers_group_id "$k8s_routers_group_id" \
  --arg proxy_group_id "$proxy_group_id" \
  --argjson proxy_service_ids "$proxy_service_ids" \
  --arg cluster_id "$cluster_id" \
  '{
    NETBIRD_MANAGEMENT_URL: $management_url,
    TRAEFIK_RESOURCE_ADDRESS: $traefik_address,
    TRAEFIK_NETWORK_RESOURCE_ADDRESS: $traefik_network_resource_address,
    TRAEFIK_RESOURCE_ID: $traefik_resource_id,
    ADMINS_GROUP_ID: $admins_group_id,
    MANAGEMENT_VM_GROUP_ID: $management_vm_group_id,
    K8S_ROUTERS_GROUP_ID: $k8s_routers_group_id,
    PROXY_GROUP_ID: $proxy_group_id,
    PROXY_SERVICE_IDS: $proxy_service_ids,
    CLUSTER_ID: $cluster_id
  }' >"$network_secret"
chmod 600 "$network_secret"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating wildcard DNS record for NetBird proxy"
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -

# Remove stale tunnel wildcard if transitioning from Cloudflare Tunnel
kubectl delete dnsendpoint cloudflare-tunnel-dns -n external-dns --ignore-not-found 2>/dev/null || true

# Create wildcard A record pointing all subdomains to the NetBird proxy
kubectl apply -f - <<EOF
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: netbird-wildcard-dns
  namespace: external-dns
spec:
  endpoints:
    - dnsName: "*.${public_zone_name}"
      recordType: A
      targets:
        - ${netbird_proxy_ip}
      recordTTL: 300
EOF

wait_for_public_oidc_discovery "$netbird_oidc_issuer"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Registering Authentik as NetBird identity provider"
idp_workdir="$MANAGER_DATA_DIR/opentofu/netbird-idp-${cluster_id}"
mkdir -p "$idp_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird-idp/"* "$idp_workdir/"
cd "$idp_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "netbird_token=$netbird_token" \
  -var "netbird_management_url=$netbird_management_url" \
  -var "client_id=$netbird_oidc_client_id" \
  -var "client_secret=$netbird_oidc_client_secret" \
  -var "issuer=$netbird_oidc_issuer"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as netbird"
cluster_file="$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
if [[ -f "$cluster_file" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "netbird"' "$cluster_file" >"$tmp_file"
  mv "$tmp_file" "$cluster_file"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg ingress_strategy "netbird" \
    --arg netbird_management_url "$netbird_management_url" \
    --arg traefik_resource_address "$traefik_resource_address" \
    --arg traefik_network_resource_address "$traefik_network_resource_address" \
    --arg traefik_resource_id "$traefik_resource_id" \
    --arg cluster_id "$cluster_id" \
    '{
      status: $status,
      outputs: {
        ingress_strategy: $ingress_strategy,
        netbird_management_url: $netbird_management_url,
        traefik_resource_address: $traefik_resource_address,
        traefik_network_resource_address: $traefik_network_resource_address,
        traefik_resource_id: $traefik_resource_id,
        cluster_id: $cluster_id
      }
    }' >"$STEP_RESULT_FILE"
fi
