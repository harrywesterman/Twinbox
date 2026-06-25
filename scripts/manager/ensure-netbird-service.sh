#!/usr/bin/env bash
set -euo pipefail

# ensure-netbird-service.sh
# Creates or updates a NetBird reverse proxy service.
# Reads credentials from the bastion secret — apps don't need to pass them.

usage() {
  echo "Usage: $0 --service-name <name> --service-domain <domain> [--service-path /]" >&2
  echo "          [--target-type <host|domain|cluster>] [--target-id <id>]" >&2
  echo "          [--target-host <host>] [--target-port <port>] [--target-protocol <http|https>]" >&2
  echo "          [--target-direct-upstream <true|false>] [--target-skip-tls-verify <true|false>]" >&2
  echo "       $0 --normalize-collection <field> < json" >&2
  exit 1
}

SERVICE_NAME=""
SERVICE_DOMAIN=""
SERVICE_PATH="/"
NORMALIZE_COLLECTION_FIELD=""
TARGET_TYPE_OVERRIDE=""
TARGET_ID_OVERRIDE=""
TARGET_HOST_OVERRIDE=""
TARGET_PORT_OVERRIDE=""
TARGET_PROTOCOL_OVERRIDE=""
TARGET_DIRECT_UPSTREAM_OVERRIDE=""
TARGET_SKIP_TLS_VERIFY_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)  SERVICE_NAME="$2"; shift 2 ;;
    --service-domain) SERVICE_DOMAIN="$2"; shift 2 ;;
    --service-path)  SERVICE_PATH="$2"; shift 2 ;;
    --normalize-collection) NORMALIZE_COLLECTION_FIELD="$2"; shift 2 ;;
    --target-type) TARGET_TYPE_OVERRIDE="$2"; shift 2 ;;
    --target-id) TARGET_ID_OVERRIDE="$2"; shift 2 ;;
    --target-host) TARGET_HOST_OVERRIDE="$2"; shift 2 ;;
    --target-port) TARGET_PORT_OVERRIDE="$2"; shift 2 ;;
    --target-protocol) TARGET_PROTOCOL_OVERRIDE="$2"; shift 2 ;;
    --target-direct-upstream) TARGET_DIRECT_UPSTREAM_OVERRIDE="$2"; shift 2 ;;
    --target-skip-tls-verify) TARGET_SKIP_TLS_VERIFY_OVERRIDE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

log_skip() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

normalize_netbird_collection() {
  local preferred_field="$1"

  jq -c --arg preferred_field "$preferred_field" '
    def collection($field):
      if type == "array" then .
      elif type == "object" then
        (
          if $field != "" and (.[$field] | type) == "array" then .[$field]
          elif (.clusters | type) == "array" then .clusters
          elif (.results | type) == "array" then .results
          elif (.items | type) == "array" then .items
          elif (.resources | type) == "array" then .resources
          else []
          end
        )
      else []
      end;
    collection($preferred_field)
  '
}

if [[ -n "$NORMALIZE_COLLECTION_FIELD" ]]; then
  normalize_netbird_collection "$NORMALIZE_COLLECTION_FIELD"
  exit 0
fi

[[ -n "$SERVICE_NAME" ]] || usage
[[ -n "$SERVICE_DOMAIN" ]] || usage

api_get() {
  local url="$1"
  local label="$2"
  local tmp_file
  local http_status

  tmp_file="$(mktemp)"
  http_status="$(curl -sS -f \
    -H "Authorization: Bearer ${NETBIRD_TOKEN}" \
    -H "Accept: application/json" \
    -o "$tmp_file" \
    -w '%{http_code}' \
    "$url")" || {
    log_skip "NetBird ${label} request failed; skipping service creation for ${SERVICE_NAME}."
    rm -f "$tmp_file"
    return 1
  }

  if [[ ! "$http_status" =~ ^2 ]]; then
    log_skip "NetBird ${label} request returned HTTP ${http_status:-<empty>}; skipping service creation for ${SERVICE_NAME}."
    rm -f "$tmp_file"
    return 1
  fi
  if ! jq -e . "$tmp_file" >/dev/null 2>&1; then
    log_skip "NetBird ${label} response was not JSON; skipping service creation for ${SERVICE_NAME}."
    rm -f "$tmp_file"
    return 1
  fi

  cat "$tmp_file"
  rm -f "$tmp_file"
}

api_get_services() {
  local tmp_file
  local http_status

  tmp_file="$(mktemp)"
  http_status="$(curl -sS -f -G \
    -H "Authorization: Bearer ${NETBIRD_TOKEN}" \
    -H "Accept: application/json" \
    --data-urlencode "domain=${SERVICE_DOMAIN}" \
    --data-urlencode "name=${SERVICE_NAME}" \
    --data-urlencode "page_size=500" \
    -o "$tmp_file" \
    -w '%{http_code}' \
    "${NETBIRD_REVERSE_PROXY_API}/services")" || {
    log_skip "NetBird service lookup failed; skipping service creation for ${SERVICE_NAME}."
    rm -f "$tmp_file"
    return 1
  }

  if [[ ! "$http_status" =~ ^2 ]]; then
    log_skip "NetBird service lookup returned HTTP ${http_status:-<empty>}; skipping service creation for ${SERVICE_NAME}."
    rm -f "$tmp_file"
    return 1
  fi
  if ! jq -e . "$tmp_file" >/dev/null 2>&1; then
    log_skip "NetBird service lookup response was not JSON; skipping service creation for ${SERVICE_NAME}."
    rm -f "$tmp_file"
    return 1
  fi

  cat "$tmp_file"
  rm -f "$tmp_file"
}

CLUSTER_ID="${CLUSTER_ID:-}"
NETBIRD_BASTION_SECRET="${TWINBOX_NETBIRD_BASTION_SECRET:-}"

# Locate the bastion secret file
if [[ -z "$NETBIRD_BASTION_SECRET" ]]; then
  if [[ -n "$CLUSTER_ID" && -f "/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${CLUSTER_ID}.json" ]]; then
    NETBIRD_BASTION_SECRET="/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${CLUSTER_ID}.json"
  else
    NETBIRD_BASTION_SECRET="$(find /opt/twinbox/bootstrap/secrets/global \
      -maxdepth 1 \
      -type f \
      -name 'netbird-bastion-*.json' \
      ! -name 'netbird-bastion-exit-router-*.json' \
      -print 2>/dev/null | sort | tail -n1 || true)"
  fi
fi

if [[ -z "$NETBIRD_BASTION_SECRET" || ! -f "$NETBIRD_BASTION_SECRET" ]]; then
  log_skip "No NetBird bastion secret found; skipping service creation (NetBird ingress route not selected)."
  exit 0
fi

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

NETBIRD_TOKEN="${TWINBOX_NETBIRD_TOKEN:-${NETBIRD_TOKEN:-}}"
if [[ -z "$NETBIRD_TOKEN" ]]; then
  NETBIRD_TOKEN="$(jq -r '.NETBIRD_SETUP_TOKEN // empty' "$NETBIRD_BASTION_SECRET")"
fi
NETBIRD_URL="${TWINBOX_NETBIRD_URL:-${NETBIRD_URL:-}}"
if [[ -z "$NETBIRD_URL" ]]; then
  NETBIRD_URL="$(jq -r '.NETBIRD_URL // empty' "$NETBIRD_BASTION_SECRET")"
fi
NETBIRD_FQDN="$(jq -r '.NETBIRD_FQDN // empty' "$NETBIRD_BASTION_SECRET")"
NETBIRD_CLUSTER_ID="$(jq -r '.CLUSTER_ID // empty' "$NETBIRD_BASTION_SECRET")"
NETBIRD_IP="$(jq -r '.NETBIRD_IP // empty' "$NETBIRD_BASTION_SECRET")"
NETBIRD_REVERSE_PROXY_API="${NETBIRD_URL%/}/api/reverse-proxies"

# Derive proxy domain from the zone (now the zone itself, not proxy.<zone>)
NETBIRD_PROXY_DOMAIN="$(jq -r '.NETBIRD_PROXY_DOMAIN // empty' "$NETBIRD_BASTION_SECRET")"
if [[ -z "$NETBIRD_PROXY_DOMAIN" && -n "$NETBIRD_FQDN" ]]; then
  # netbird.<zone> → strip "netbird." prefix
  NETBIRD_PROXY_DOMAIN="${NETBIRD_FQDN#netbird.}"
fi

if [[ -z "$NETBIRD_TOKEN" ]]; then
  log_skip "No NetBird setup token found; skipping service creation (NetBird ingress route not selected)."
  exit 0
fi
if [[ -z "$NETBIRD_URL" ]]; then
  log_skip "No NetBird URL found; skipping service creation (NetBird ingress route not selected)."
  exit 0
fi
if [[ -z "$NETBIRD_PROXY_DOMAIN" ]]; then
  log_skip "No NetBird proxy domain found; skipping service creation for ${SERVICE_NAME}."
  exit 0
fi

# Find the Traefik network resource ID from the network secret
TRAEFIK_RESOURCE_ID=""
TRAEFIK_RESOURCE_ADDRESS=""
TRAEFIK_TARGET_PORT="443"
TRAEFIK_TARGET_PROTOCOL="https"
if [[ -n "$NETBIRD_CLUSTER_ID" ]]; then
  NETWORK_SECRET="/opt/twinbox/bootstrap/secrets/global/netbird-network-${NETBIRD_CLUSTER_ID}.json"
  if [[ -f "$NETWORK_SECRET" ]]; then
    TRAEFIK_RESOURCE_ID="$(jq -r '.TRAEFIK_RESOURCE_ID // empty' "$NETWORK_SECRET")"
    TRAEFIK_RESOURCE_ADDRESS="$(jq -r '.TRAEFIK_RESOURCE_ADDRESS // empty' "$NETWORK_SECRET")"
    TRAEFIK_TARGET_PORT="$(jq -r '.TRAEFIK_TARGET_PORT // "443"' "$NETWORK_SECRET")"
    TRAEFIK_TARGET_PROTOCOL="$(jq -r '.TRAEFIK_TARGET_PROTOCOL // empty' "$NETWORK_SECRET")"
  fi
fi
if [[ -z "$TRAEFIK_TARGET_PROTOCOL" ]]; then
  if [[ "$TRAEFIK_TARGET_PORT" == "8082" ]]; then
    TRAEFIK_TARGET_PROTOCOL="http"
  else
    TRAEFIK_TARGET_PROTOCOL="https"
  fi
fi

TARGET_ID="${TARGET_ID_OVERRIDE:-$TRAEFIK_RESOURCE_ID}"
TARGET_HOST="${TARGET_HOST_OVERRIDE:-$TRAEFIK_RESOURCE_ADDRESS}"
TARGET_PORT="${TARGET_PORT_OVERRIDE:-$TRAEFIK_TARGET_PORT}"
TARGET_PROTOCOL="${TARGET_PROTOCOL_OVERRIDE:-$TRAEFIK_TARGET_PROTOCOL}"
TARGET_DIRECT_UPSTREAM="${TARGET_DIRECT_UPSTREAM_OVERRIDE:-false}"
if [[ -n "$TARGET_SKIP_TLS_VERIFY_OVERRIDE" ]]; then
  TARGET_SKIP_TLS_VERIFY="$TARGET_SKIP_TLS_VERIFY_OVERRIDE"
elif [[ "$TARGET_PROTOCOL" == "https" ]]; then
  TARGET_SKIP_TLS_VERIFY="true"
else
  TARGET_SKIP_TLS_VERIFY="false"
fi

if [[ -n "$TARGET_TYPE_OVERRIDE" ]]; then
  TARGET_TYPE="$TARGET_TYPE_OVERRIDE"
elif [[ "$TARGET_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  TARGET_TYPE="host"
else
  TARGET_TYPE="domain"
fi

if [[ -z "$TARGET_ID" ]]; then
  log_skip "NetBird network secret not ready; skipping service creation for ${SERVICE_NAME}."
  exit 0
fi
if [[ -z "$TARGET_HOST" ]]; then
  log_skip "NetBird network secret does not contain TRAEFIK_RESOURCE_ADDRESS; skipping service creation for ${SERVICE_NAME}."
  exit 0
fi
case "$TARGET_TYPE" in
  host|domain|cluster) ;;
  *)
    log_skip "NetBird target type ${TARGET_TYPE} is not supported; skipping service creation for ${SERVICE_NAME}."
    exit 0
    ;;
esac
case "$TARGET_PROTOCOL" in
  http|https) ;;
  *)
    log_skip "NetBird target protocol ${TARGET_PROTOCOL} is not supported; skipping service creation for ${SERVICE_NAME}."
    exit 0
    ;;
esac
if [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  log_skip "NetBird target port ${TARGET_PORT} is invalid; skipping service creation for ${SERVICE_NAME}."
  exit 0
fi
case "$TARGET_DIRECT_UPSTREAM" in
  true|false) ;;
  *)
    log_skip "NetBird target direct_upstream value ${TARGET_DIRECT_UPSTREAM} is invalid; skipping service creation for ${SERVICE_NAME}."
    exit 0
    ;;
esac
case "$TARGET_SKIP_TLS_VERIFY" in
  true|false) ;;
  *)
    log_skip "NetBird target skip_tls_verify value ${TARGET_SKIP_TLS_VERIFY} is invalid; skipping service creation for ${SERVICE_NAME}."
    exit 0
    ;;
esac

# 1. Find the proxy cluster by domain
find_proxy_cluster() {
  local response
  response="$(api_get "${NETBIRD_REVERSE_PROXY_API}/clusters" "proxy cluster lookup")" || return 1
  printf '%s' "$response" \
    | normalize_netbird_collection "clusters" \
    | jq -r '.[]? | select(.address == "'"$NETBIRD_PROXY_DOMAIN"'") | .id // empty' \
    | head -n1
}

PROXY_CLUSTER_ID="$(find_proxy_cluster || true)"
if [[ -z "$PROXY_CLUSTER_ID" ]]; then
  log_skip "No NetBird reverse proxy cluster found for $NETBIRD_PROXY_DOMAIN; skipping service creation for ${SERVICE_NAME}."
  exit 0
fi

# 1.5. Ensure the domain exists before creating services
# The Terraform module creates netbird_reverse_proxy_domain first.
ensure_netbird_domain() {
  local domains_json
  local existing_domain_id
  local existing_target_cluster

  domains_json="$(api_get "${NETBIRD_REVERSE_PROXY_API}/domains" "domain lookup")" || return 1
  existing_domain_id="$(
    printf '%s' "$domains_json" \
      | normalize_netbird_collection "domains" \
      | jq -r '.[]? | select(.domain == "'"$SERVICE_DOMAIN"'") | .id // empty' \
      | head -n1
  )"
  existing_target_cluster="$(
    printf '%s' "$domains_json" \
      | normalize_netbird_collection "domains" \
      | jq -r '.[]? | select(.domain == "'"$SERVICE_DOMAIN"'") | .target_cluster // .targetCluster // empty' \
      | head -n1
  )"

  if [[ -n "$existing_domain_id" ]]; then
    if [[ -n "$existing_target_cluster" && "$existing_target_cluster" != "$NETBIRD_PROXY_DOMAIN" ]]; then
      log_skip "NetBird domain ${SERVICE_DOMAIN} already targets ${existing_target_cluster}, expected ${NETBIRD_PROXY_DOMAIN}; skipping service creation."
      return 1
    fi
    return 0
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird reverse proxy domain: ${SERVICE_DOMAIN}"
  local http_status
  http_status="$(curl -sS -f \
    -X POST \
    -H "Authorization: Bearer ${NETBIRD_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$(jq -cn --arg domain "$SERVICE_DOMAIN" --arg cluster "$NETBIRD_PROXY_DOMAIN" '{domain: $domain, target_cluster: $cluster}')" \
    -o /dev/null -w '%{http_code}' \
    "${NETBIRD_REVERSE_PROXY_API}/domains")" || true
  if [[ ! "$http_status" =~ ^2 ]]; then
    log_skip "NetBird domain creation returned HTTP ${http_status:-<empty>}; skipping service creation for ${SERVICE_NAME}."
    return 1
  fi
  return 0
}

ensure_netbird_domain || exit 0

# 2. Check if service already exists
check_existing_service() {
  local response
  response="$(api_get_services)" || return 1
  printf '%s' "$response" \
    | normalize_netbird_collection "services" \
    | jq -r '.[]? | select(.domain == "'"$SERVICE_DOMAIN"'" and .name == "'"$SERVICE_NAME"'") | .id // empty' \
    | head -n1
}

EXISTING_SERVICE_ID="$(check_existing_service || true)"

# 3. Build the service payload. The network step creates the Traefik resource
# and writes its ID to the network secret; the live cluster resources endpoint
# can be unavailable on some NetBird versions, so do not re-discover it here.
build_service_payload() {
  jq -cn \
    --arg name "$SERVICE_NAME" \
    --arg domain "$SERVICE_DOMAIN" \
    --arg target_id "$TARGET_ID" \
    --arg target_type "$TARGET_TYPE" \
    --arg host "$TARGET_HOST" \
    --arg path "$SERVICE_PATH" \
    --arg protocol "$TARGET_PROTOCOL" \
    --argjson target_port "$TARGET_PORT" \
    --argjson service_enabled "true" \
    --argjson direct_upstream "$TARGET_DIRECT_UPSTREAM" \
    --argjson skip_tls_verify "$TARGET_SKIP_TLS_VERIFY" \
    '{
      name: $name,
      domain: $domain,
      enabled: $service_enabled,
      pass_host_header: true,
      rewrite_redirects: true,
      targets: [{
        target_id: $target_id,
        target_type: $target_type,
        host: $host,
        path: $path,
        port: $target_port,
        protocol: $protocol,
        options: {
          direct_upstream: $direct_upstream,
          skip_tls_verify: $skip_tls_verify
        },
        enabled: $service_enabled
      }],
      auth: {
        link_auth: { enabled: false },
        password_auth: { enabled: false },
        pin_auth: { enabled: false },
        bearer_auth: { enabled: false }
      }
    }'
}

# 4. Create or update the service
if [[ -n "$EXISTING_SERVICE_ID" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updating existing NetBird service: ${SERVICE_NAME} (id: ${EXISTING_SERVICE_ID})"
  http_status="$(curl -sS -f \
    -X PUT \
    -H "Authorization: Bearer ${NETBIRD_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$(build_service_payload "$EXISTING_SERVICE_ID")" \
    -o /dev/null -w '%{http_code}' \
    "${NETBIRD_REVERSE_PROXY_API}/services/${EXISTING_SERVICE_ID}")" || true
  if [[ "$http_status" =~ ^2 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird service ${SERVICE_NAME} -> ${SERVICE_DOMAIN}${SERVICE_PATH} configured"
  else
    log_skip "NetBird PUT returned HTTP ${http_status:-<empty>}; skipping service creation for ${SERVICE_NAME}."
    exit 0
  fi
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird reverse proxy service: ${SERVICE_NAME}"
  http_status="$(curl -sS -f \
    -X POST \
    -H "Authorization: Bearer ${NETBIRD_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$(build_service_payload "")" \
    -o /dev/null -w '%{http_code}' \
    "${NETBIRD_REVERSE_PROXY_API}/services")" || true
  if [[ "$http_status" =~ ^2 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird service ${SERVICE_NAME} -> ${SERVICE_DOMAIN}${SERVICE_PATH} configured"
  else
    log_skip "NetBird POST returned HTTP ${http_status:-<empty>}; skipping service creation for ${SERVICE_NAME}."
    exit 0
  fi
fi
