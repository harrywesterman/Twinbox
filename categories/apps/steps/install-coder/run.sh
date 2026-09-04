#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

resolve_kubeconfig_file() {
  if [[ -z "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE is required"
  fi

  if [[ ! -f "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE does not exist at ${KUBECONFIG_FILE:-}"
  fi

  printf '%s\n' "$KUBECONFIG_FILE"
}

wait_for_resource_ready() {
  local namespace="$1"
  local resource="$2"
  local condition="$3"
  local label="$4"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" get "$resource" >/dev/null 2>&1; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$resource" --timeout=5s >/dev/null 2>&1; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} to become ready"
    else
      log "Waiting for ${label} to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become ready after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

render_template() {
  local template_file="$1"
  local rendered_file="$2"
  shift 2

  python3 - "$template_file" "$rendered_file" "$@" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1]).read_text(encoding="utf-8")
rendered = template
for item in sys.argv[3:]:
    key, value = item.split("=", 1)
    rendered = rendered.replace(key, value)
Path(sys.argv[2]).write_text(rendered, encoding="utf-8")
PY
}

extract_first_ipv4() {
  awk '
    match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  '
}

find_netbird_bastion_secret() {
  local secrets_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"
  local expected_secret="${secrets_dir}/netbird-bastion-${cluster_id}.json"

  if [[ -f "$expected_secret" ]]; then
    printf '%s\n' "$expected_secret"
    return 0
  fi

  [[ -d "$secrets_dir" ]] || return 0

  find "$secrets_dir" \
    -maxdepth 1 \
    -type f \
    -name 'netbird-bastion-*.json' \
    ! -name 'netbird-bastion-exit-router-*.json' \
    2>/dev/null | sort | head -n1
}

netbird_peer_ip_by_name() {
  local hostname="$1"

  python3 - "$netbird_management_url" "$netbird_token" "$hostname" <<'PY' 2>/dev/null || true
import json
import sys
import urllib.parse
import urllib.request

management_url, token, hostname = sys.argv[1], sys.argv[2], sys.argv[3]
base_url = management_url.rstrip("/")
if base_url.endswith("/api"):
    base_url = base_url[:-4]
url = f"{base_url}/api/peers?name={urllib.parse.quote(hostname)}"
for auth_scheme in ("Token", "Bearer"):
    req = urllib.request.Request(url, headers={"Authorization": f"{auth_scheme} {token}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            peers = json.loads(resp.read().decode())
        break
    except Exception:
        peers = None
if isinstance(peers, dict):
    peers = peers.get("peers") or peers.get("items") or peers.get("results") or []
if not isinstance(peers, list):
    peers = []
for peer in peers:
    if peer.get("name") == hostname and peer.get("ip"):
        print(str(peer["ip"]).split("/", 1)[0])
        break
PY
}

discover_management_netbird_ip() {
  local mgmt_netbird_status=""
  local mgmt_netbird_ip=""

  if command -v netbird >/dev/null 2>&1; then
    mgmt_netbird_ip="$(netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 || true)"
    mgmt_netbird_status="$(netbird status 2>/dev/null || true)"
  fi

  if [[ -z "$mgmt_netbird_status" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    mgmt_netbird_ip="$(docker exec twinbox-netbird netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 || true)"
    mgmt_netbird_status="$(docker exec twinbox-netbird netbird status 2>/dev/null || true)"
  fi

  if [[ -z "$mgmt_netbird_ip" ]]; then
    mgmt_netbird_ip="$(printf '%s\n' "$mgmt_netbird_status" | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 2>/dev/null || true)"
  fi

  if [[ -z "$mgmt_netbird_ip" ]]; then
    mgmt_netbird_ip="$(netbird_peer_ip_by_name "twinbox-mgmt-${cluster_slug}")"
  fi

  printf '%s\n' "$mgmt_netbird_ip" | extract_first_ipv4
}

discover_bastion_netbird_ip() {
  local bastion_netbird_ip=""

  bastion_netbird_ip="$(jq -r '.NETBIRD_PRIVATE_IP // empty' "$netbird_bastion_secret" | extract_first_ipv4)"
  if [[ -z "$bastion_netbird_ip" ]]; then
    bastion_netbird_ip="$(netbird_peer_ip_by_name "twinbox-${cluster_id}-proxy")"
  fi

  printf '%s\n' "$bastion_netbird_ip" | extract_first_ipv4
}

publish_coder_workspace_access() {
  local mgmt_netbird_ip="$1"
  local bastion_netbird_ip="$2"

  kubectl create namespace coder-workspaces --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n coder-workspaces create configmap coder-workspace-access \
    --from-literal=TWINBOX_CLUSTER_ID="$cluster_id" \
    --from-literal=TWINBOX_PUBLIC_ZONE="$public_zone_name" \
    --from-literal=TWINBOX_REPO_URL="${TWINBOX_GIT_REPO_URL}" \
    --from-literal=TWINBOX_MANAGEMENT_VM_NETBIRD_IP="$mgmt_netbird_ip" \
    --from-literal=TWINBOX_MANAGEMENT_VM_USER="${TWINBOX_MANAGEMENT_VM_USER:-twinbox}" \
    --from-literal=TWINBOX_MANAGEMENT_VM_SSH_PORT="${TWINBOX_MANAGEMENT_VM_SSH_PORT:-22}" \
    --from-literal=TWINBOX_BASTION_NETBIRD_IP="$bastion_netbird_ip" \
    --from-literal=TWINBOX_BASTION_SSH_USER="$bastion_ssh_user" \
    --from-literal=TWINBOX_BASTION_SSH_PORT="$bastion_ssh_port" \
    --dry-run=client -o yaml | kubectl apply -f -
}

coder_port_forward_pid=""
coder_port_forward_log=""
coder_port_forward_url=""
coder_resolved_session_token=""

stop_coder_port_forward() {
  if [[ -n "${coder_port_forward_pid:-}" ]] && kill -0 "$coder_port_forward_pid" >/dev/null 2>&1; then
    kill "$coder_port_forward_pid" >/dev/null 2>&1 || true
    wait "$coder_port_forward_pid" >/dev/null 2>&1 || true
  fi
  coder_port_forward_pid=""
}

start_coder_port_forward() {
  local port="${TWINBOX_CODER_PORT_FORWARD_PORT:-17080}"
  local attempt

  coder_port_forward_log="$(mktemp "${TMPDIR:-/tmp}/coder-port-forward-XXXXXX.log")"
  kubectl -n coder port-forward service/coder "${port}:80" >"$coder_port_forward_log" 2>&1 &
  coder_port_forward_pid="$!"

  for attempt in $(seq 1 40); do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      coder_port_forward_url="http://127.0.0.1:${port}"
      return 0
    fi

    if ! kill -0 "$coder_port_forward_pid" >/dev/null 2>&1; then
      fail "Coder port-forward exited early: $(tail -n 20 "$coder_port_forward_log" 2>/dev/null | tr '\n' ' ')"
    fi

    sleep 1
  done

  fail "Coder port-forward did not become reachable on localhost:${port}: $(tail -n 20 "$coder_port_forward_log" 2>/dev/null | tr '\n' ' ')"
}

sync_coder_secret() {
  jq -n \
    --arg CODER_POSTGRESQL__USERNAME "$coder_db_username" \
    --arg CODER_POSTGRESQL__PASSWORD "$coder_db_password" \
    --arg DATABASE_URL "$coder_database_url" \
    --arg CODER_OIDC_CLIENT_ID "$coder_oauth_client_id" \
    --arg CODER_OIDC_CLIENT_SECRET "$coder_oauth_client_secret" \
    --arg CODER_BOOTSTRAP_ADMIN_USERNAME "$coder_bootstrap_admin_username" \
    --arg CODER_BOOTSTRAP_ADMIN_EMAIL "$coder_bootstrap_admin_email" \
    --arg CODER_BOOTSTRAP_ADMIN_PASSWORD "$coder_bootstrap_admin_password" \
    --arg CODER_TEMPLATE_SESSION_TOKEN "$coder_template_session_token" \
    '{
      CODER_POSTGRESQL__USERNAME: $CODER_POSTGRESQL__USERNAME,
      CODER_POSTGRESQL__PASSWORD: $CODER_POSTGRESQL__PASSWORD,
      DATABASE_URL: $DATABASE_URL,
      CODER_OIDC_CLIENT_ID: $CODER_OIDC_CLIENT_ID,
      CODER_OIDC_CLIENT_SECRET: $CODER_OIDC_CLIENT_SECRET,
      CODER_BOOTSTRAP_ADMIN_USERNAME: $CODER_BOOTSTRAP_ADMIN_USERNAME,
      CODER_BOOTSTRAP_ADMIN_EMAIL: $CODER_BOOTSTRAP_ADMIN_EMAIL,
      CODER_BOOTSTRAP_ADMIN_PASSWORD: $CODER_BOOTSTRAP_ADMIN_PASSWORD
    }
    + (
      if $CODER_TEMPLATE_SESSION_TOKEN == "" then {}
      else {CODER_TEMPLATE_SESSION_TOKEN: $CODER_TEMPLATE_SESSION_TOKEN}
      end
    )' >"$coder_secret_file"

  log "Writing Coder bootstrap secret to OpenBao"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "coder" \
    --json-file "$coder_secret_file" \
    --required-keys "CODER_POSTGRESQL__USERNAME,CODER_POSTGRESQL__PASSWORD,DATABASE_URL,CODER_OIDC_CLIENT_ID,CODER_OIDC_CLIENT_SECRET,CODER_BOOTSTRAP_ADMIN_USERNAME,CODER_BOOTSTRAP_ADMIN_EMAIL,CODER_BOOTSTRAP_ADMIN_PASSWORD"
}

ensure_coder_template_session_token() {
  local configured_token="${CODER_SESSION_TOKEN:-${TWINBOX_CODER_SESSION_TOKEN:-}}"
  local coder_home token login_log

  if [[ -n "$configured_token" ]]; then
    coder_resolved_session_token="$configured_token"
    return 0
  fi

  if [[ -n "$coder_template_session_token" ]]; then
    coder_resolved_session_token="$coder_template_session_token"
    return 0
  fi

  coder_home="$(mktemp -d "${TMPDIR:-/tmp}/coder-bootstrap-home-XXXXXX")"
  login_log="$(mktemp "${TMPDIR:-/tmp}/coder-login-XXXXXX.log")"

  log "No Coder template token found; bootstrapping the first Coder admin user if this is a fresh deployment"
  if ! HOME="$coder_home" \
      CODER_FIRST_USER_USERNAME="$coder_bootstrap_admin_username" \
      CODER_FIRST_USER_EMAIL="$coder_bootstrap_admin_email" \
      CODER_FIRST_USER_FULL_NAME="Twinbox Bootstrap Admin" \
      CODER_FIRST_USER_PASSWORD="$coder_bootstrap_admin_password" \
      CODER_FIRST_USER_TRIAL="false" \
      timeout 90s coder login "$coder_port_forward_url" </dev/null >"$login_log" 2>&1; then
    rm -rf "$coder_home"
    fail "Could not bootstrap a Coder template token. If Coder already has users, set TWINBOX_CODER_SESSION_TOKEN or CODER_SESSION_TOKEN and rerun install-coder. Details: $(tail -n 20 "$login_log" 2>/dev/null | tr '\n' ' ')"
  fi

  token="$(HOME="$coder_home" CODER_URL="$coder_port_forward_url" coder login token)"
  rm -rf "$coder_home"
  [[ -n "$token" ]] || fail "Coder login succeeded but did not return a session token"

  coder_template_session_token="$token"
  coder_resolved_session_token="$token"
  sync_coder_secret
}

push_coder_template() {
  local template_dir="$WORKSPACE_ROOT/infra/coder/templates/twinbox-development"
  local session_token=""
  local commit_short=""
  local dev_workspace_image="ghcr.io/harrywesterman/twinbox-dev-workspace:latest"

  if commit_short="$(git -C "$WORKSPACE_ROOT" rev-parse --short=7 HEAD 2>/dev/null)"; then
    dev_workspace_image="ghcr.io/harrywesterman/twinbox-dev-workspace:sha-${commit_short}"
  fi

  if ! command -v coder >/dev/null 2>&1; then
    fail "coder CLI is not installed in the manager worker image; rebuild the Management VM worker image before installing Coder"
  fi

  start_coder_port_forward
  ensure_coder_template_session_token
  session_token="$coder_resolved_session_token"

  log "Pushing Twinbox development Coder template"
  CODER_URL="$coder_port_forward_url" CODER_SESSION_TOKEN="$session_token" \
    coder templates push twinbox-development \
      --directory "$template_dir" \
      --yes \
      --variable "image=${dev_workspace_image}" \
      --variable "netbird_version=${PINNED_NETBIRD_VERSION}" \
      --variable "repo_url=${TWINBOX_GIT_REPO_URL}"
  stop_coder_port_forward
}

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?page_size=200")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response

  response="$(authentik_api_get "/core/applications/?page_size=200")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Coder")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_payload="$1"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "coder" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/coder/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

sync_shared_ai_endpoint_if_configured() {
  MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"
  if [[ ! -f "${MANAGER_DATA_DIR}/agents/provider.json" ]]; then
    log "Shared AI endpoint is not configured; skipping Coder AI sync"
    return 0
  fi

  log "Syncing shared AI endpoint to Coder"
  MANAGER_DATA_DIR="$MANAGER_DATA_DIR" \
  WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-${WORKSPACE_ROOT}/bootstrap}" \
  TWINBOX_CLUSTER_ID="$cluster_id" \
  TWINBOX_CLUSTER_INSTANCE_ID="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // empty')" \
  bash "$WORKSPACE_ROOT/scripts/manager/sync-twinbox-agents-config.sh"
}

ensure_shared_ai_secret_baseline() {
  log "Ensuring shared AI endpoint secret baseline"
  WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  bash "$WORKSPACE_ROOT/scripts/manager/ensure-shared-ai-secret.sh"
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

netbird_bastion_secret="$(find_netbird_bastion_secret)"
[[ -n "$netbird_bastion_secret" && -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found; run configure-netbird-ingress before installing Coder workspaces"
netbird_management_url="$(jq -r '.NETBIRD_URL // empty' "$netbird_bastion_secret")"
netbird_token="$(jq -r '.NETBIRD_ADMIN_TOKEN // .NETBIRD_API_TOKEN // .NETBIRD_SETUP_TOKEN // empty' "$netbird_bastion_secret")"
bastion_ssh_port="$(jq -r '.BASTION_SSH_PORT // "22"' "$netbird_bastion_secret")"
bastion_ssh_user="$(jq -r '.BASTION_SSH_USER // "root"' "$netbird_bastion_secret")"
[[ -n "$netbird_management_url" ]] || fail "NETBIRD_URL is missing from ${netbird_bastion_secret}"
[[ -n "$netbird_token" ]] || fail "NETBIRD_ADMIN_TOKEN or NETBIRD_SETUP_TOKEN is missing from ${netbird_bastion_secret}"
[[ "$bastion_ssh_port" =~ ^[0-9]+$ ]] || fail "BASTION_SSH_PORT is invalid in ${netbird_bastion_secret}"
[[ -n "$bastion_ssh_user" ]] || fail "BASTION_SSH_USER is empty in ${netbird_bastion_secret}"

log "Discovering NetBird addresses for Twinbox development workspaces"
mgmt_netbird_ip="$(discover_management_netbird_ip)"
[[ -n "$mgmt_netbird_ip" ]] || fail "Could not determine the Management VM NetBird IP"
bastion_netbird_ip="$(discover_bastion_netbird_ip)"
[[ -n "$bastion_netbird_ip" ]] || fail "Could not determine the bastion NetBird IP; run configure-netbird-ingress first"
publish_coder_workspace_access "$mgmt_netbird_ip" "$bastion_netbird_ip"

authentik_ensure_token
authentik_setup_forward

CODER_HOST="https://coder.${public_zone_name}"
CODER_REDIRECT_URI="${CODER_HOST}/oauth/callback"

coder_db_username="coder"
coder_db_password="$(openssl rand -hex 24)"
coder_oauth_client_id="$(openssl rand -hex 16)"
coder_oauth_client_secret="$(openssl rand -hex 24)"
coder_database_url="postgres://${coder_db_username}:${coder_db_password}@coder-db-pooler-rw-session.databases.svc.cluster.local:5432/coder"
coder_oidc_issuer="https://authentik.${public_zone_name}/application/o/coder/"
coder_bootstrap_admin_username="${TWINBOX_CODER_BOOTSTRAP_ADMIN_USERNAME:-twinbox-admin}"
coder_bootstrap_admin_email="${TWINBOX_CODER_BOOTSTRAP_ADMIN_EMAIL:-${coder_bootstrap_admin_username}@${public_zone_name}}"
coder_bootstrap_admin_password="$(openssl rand -base64 36 | tr -d '\n')"
coder_template_session_token="${TWINBOX_CODER_SESSION_TOKEN:-${CODER_SESSION_TOKEN:-}}"

existing_coder_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_coder_secret_json="$(openbao_read_global_secret_json coder 2>/dev/null || true)"
fi

if [[ -n "$existing_coder_secret_json" ]]; then
  existing_db_username="$(jq -r '.CODER_POSTGRESQL__USERNAME // empty' <<<"$existing_coder_secret_json")"
  existing_db_password="$(jq -r '.CODER_POSTGRESQL__PASSWORD // empty' <<<"$existing_coder_secret_json")"
  existing_database_url="$(jq -r '.DATABASE_URL // empty' <<<"$existing_coder_secret_json")"
  existing_oauth_client_id="$(jq -r '.CODER_OIDC_CLIENT_ID // empty' <<<"$existing_coder_secret_json")"
  existing_oauth_client_secret="$(jq -r '.CODER_OIDC_CLIENT_SECRET // empty' <<<"$existing_coder_secret_json")"
  existing_bootstrap_admin_username="$(jq -r '.CODER_BOOTSTRAP_ADMIN_USERNAME // empty' <<<"$existing_coder_secret_json")"
  existing_bootstrap_admin_email="$(jq -r '.CODER_BOOTSTRAP_ADMIN_EMAIL // empty' <<<"$existing_coder_secret_json")"
  existing_bootstrap_admin_password="$(jq -r '.CODER_BOOTSTRAP_ADMIN_PASSWORD // empty' <<<"$existing_coder_secret_json")"
  existing_template_session_token="$(jq -r '.CODER_TEMPLATE_SESSION_TOKEN // empty' <<<"$existing_coder_secret_json")"

  [[ -n "$existing_db_username" ]] && coder_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && coder_db_password="$existing_db_password"
  [[ -n "$existing_database_url" ]] && coder_database_url="$existing_database_url"
  [[ -n "$existing_oauth_client_id" ]] && coder_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && coder_oauth_client_secret="$existing_oauth_client_secret"
  [[ -n "$existing_bootstrap_admin_username" ]] && coder_bootstrap_admin_username="$existing_bootstrap_admin_username"
  [[ -n "$existing_bootstrap_admin_email" ]] && coder_bootstrap_admin_email="$existing_bootstrap_admin_email"
  [[ -n "$existing_bootstrap_admin_password" ]] && coder_bootstrap_admin_password="$existing_bootstrap_admin_password"
  [[ -n "$existing_template_session_token" ]] && coder_template_session_token="$existing_template_session_token"
fi

coder_secret_file="$(mktemp "${TMPDIR:-/tmp}/coder-bootstrap-XXXXXX")"
coder_oidc_file="$(mktemp "${TMPDIR:-/tmp}/coder-oidc-XXXXXX")"
coder_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/coder-application-XXXXXX")"
trap 'stop_coder_port_forward; rm -f "$coder_secret_file" "$coder_oidc_file" "$coder_rendered_manifest" "${coder_port_forward_log:-}"' EXIT

sync_coder_secret

jq -n \
  --arg CODER_OIDC_CLIENT_ID "$coder_oauth_client_id" \
  --arg CODER_OIDC_CLIENT_SECRET "$coder_oauth_client_secret" \
  '{
    CODER_OIDC_CLIENT_ID: $CODER_OIDC_CLIENT_ID,
    CODER_OIDC_CLIENT_SECRET: $CODER_OIDC_CLIENT_SECRET
  }' >"$coder_oidc_file"

log "Writing Coder OIDC secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "coder-oidc" \
  --json-file "$coder_oidc_file" \
  --required-keys "CODER_OIDC_CLIENT_ID,CODER_OIDC_CLIENT_SECRET"

ensure_shared_ai_secret_baseline

log "Provisioning Authentik OIDC client for Coder"
authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"

property_mappings_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Coder" \
    --arg client_id "$coder_oauth_client_id" \
    --arg client_secret "$coder_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$CODER_REDIRECT_URI" \
    --argjson property_mappings "$property_mappings_json" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $redirect_uri
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider"
    }'
)"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Coder"

application_payload="$(
  jq -n \
    --arg name "Coder" \
    --arg slug "coder" \
    --arg launch_url "$CODER_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Coder"

log "Applying Coder Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/coder.yaml" >"$coder_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$coder_rendered_manifest" \
  --application "coder" \
  --destination-namespace "coder"

wait_for_resource_ready "coder" "deployment/coder" "Available" "Coder server"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "coder" \
  --host "coder-db-pooler-rw-session.databases.svc.cluster.local"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "coder" \
  --service-domain "coder.${public_zone_name}" \
  --service-path /

push_coder_template

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "coder" \
    --arg public_url "$CODER_HOST" \
    --arg database "coder-db" \
    --arg workspace_template "twinbox-development" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database,
      workspace_template: $workspace_template
    }' >"$STEP_RESULT_FILE"
fi
sync_shared_ai_endpoint_if_configured
