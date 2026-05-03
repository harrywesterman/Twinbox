#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_slug_lower="$(printf '%s' "$cluster_slug" | tr '[:upper:]' '[:lower:]')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

ingress_route="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ingress_route')"
dns_domain="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dns_domain')"
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$dns_domain")"

case "$ingress_route" in
  wiredoor|cloudflare-tunnel|metallb|tailscale|netbird) ;;
  *)
    fail "Unsupported ingress route: $ingress_route"
    ;;
esac

if [[ "$ingress_route" == "cloudflare-tunnel" && "$cluster_slug_lower" != "prd" ]]; then
  fail "Cloudflare Tunnel is only available for prd clusters on Cloudflare Free"
fi

[[ -n "$dns_domain" ]] || fail "DNS domain is required"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Selected ingress route: $ingress_route"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Base DNS domain: $dns_domain"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public zone name: $public_zone_name"

cluster_file="$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
if [[ -f "$cluster_file" ]]; then
  tmp_file="$(mktemp)"
  jq \
    --arg ingress_route "$ingress_route" \
    --arg dns_domain "$dns_domain" \
    --arg public_zone_name "$public_zone_name" \
    '.selected_ingress_route = $ingress_route | .dns_domain = $dns_domain | .public_zone_name = $public_zone_name' \
    "$cluster_file" > "$tmp_file"
  mv "$tmp_file" "$cluster_file"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "selected_ingress_route": "$ingress_route",
  "dns_domain": "$dns_domain",
  "public_zone_name": "$public_zone_name",
  "cluster_id": "$cluster_id"
}
EOF
fi
