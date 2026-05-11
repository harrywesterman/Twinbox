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

# Parse cluster context
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

# Read dns_domain and public_zone_name from cluster context (set by configure-dns step)
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
public_zone_name="$(printf '%s' "$cluster_json" | jq -r '.public_zone_name // empty')"
if [[ -z "$public_zone_name" && -n "$cluster_dns_domain" ]]; then
  public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
fi

[[ -n "$cluster_dns_domain" ]] || fail "DNS domain not found. Please run Configure DNS step first."
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Wiredoor DNS configuration for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public zone name: $public_zone_name"

# Read Wiredoor bastion secrets (per cluster) to get the IP address
wiredoor_secrets="/opt/twinbox/bootstrap/secrets/global/wiredoor-bastion-${cluster_id}.json"
[[ -f "$wiredoor_secrets" ]] || fail "Wiredoor bastion secrets not found at $wiredoor_secrets"

target_ipv4="$(jq -r '.WIREDOOR_IP' "$wiredoor_secrets")"
[[ -n "$target_ipv4" && "$target_ipv4" != "null" ]] || fail "Could not read Wiredoor IP from secrets"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor IP: $target_ipv4"

# Generate DNS record names based on cluster slug
if [[ "$cluster_id" == "prd" ]]; then
  wiredoor_record_name="wiredoor"
  wildcard_prefix=""
else
  wiredoor_record_name="wiredoor-${cluster_id}"
  wildcard_prefix="${cluster_id}."
fi

wiredoor_fqdn="${wiredoor_record_name}.${cluster_dns_domain}"
wildcard_fqdn="*.${wildcard_prefix}${cluster_dns_domain}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wiredoor FQDN: $wiredoor_fqdn"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wildcard FQDN: $wildcard_fqdn"

# Create DNSEndpoint resources for external-dns to reconcile
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating DNSEndpoint resources"

kubectl apply -f - <<EOF
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: wiredoor-dns
  namespace: external-dns
spec:
  endpoints:
    - dnsName: ${wiredoor_fqdn}
      recordType: A
      targets:
        - ${target_ipv4}
      recordTTL: 300
    - dnsName: ${wildcard_fqdn}
      recordType: A
      targets:
        - ${target_ipv4}
      recordTTL: 300
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS records created via external-dns DNSEndpoint"

# Save hostnames to bootstrap secrets (for OpenBao sync)
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/cloudflare-${cluster_id}.json" <<EOF
{
  "ZONE_NAME": "$public_zone_name",
  "WIREDOOR_FQDN": "$wiredoor_fqdn",
  "WILDCARD_FQDN": "$wildcard_fqdn",
  "TARGET_IPV4": "$target_ipv4",
  "CLUSTER_ID": "$cluster_id"
}
EOF
chmod 600 "$secrets_dir/cloudflare-${cluster_id}.json"

# Sync hostnames to OpenBao so all platform apps can read ZONE_NAME
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "cluster-hostnames" \
  --json-file "$secrets_dir/cloudflare-${cluster_id}.json" \
  --required-keys "ZONE_NAME,WIREDOOR_FQDN,WILDCARD_FQDN"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "wiredoor_fqdn": "$wiredoor_fqdn",
  "wildcard_fqdn": "$wildcard_fqdn",
  "target_ipv4": "$target_ipv4",
  "zone_name": "$public_zone_name",
  "cluster_id": "$cluster_id"
}
EOF
fi
