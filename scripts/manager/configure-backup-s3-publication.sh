#!/usr/bin/env bash
set -euo pipefail

# configure-backup-s3-publication.sh
# Publishes the dedicated SeaweedFS backup VM admin behind the Twinbox reverse
# proxy chain:
#   1. Deploys the backup-s3 Argo CD app (namespace, service, ServersTransport,
#      Traefik IngressRoutes incl. the Authentik callback route).
#   2. Applies the runtime Endpoints that point at the backup S3 VM IP.
#   3. Creates an Authentik forward-auth proxy provider + application (admins
#      only) and attaches it to the embedded outpost.
#   4. Registers the NetBird reverse proxy service backup-s3.<zone> -> Traefik.
#
# The SeaweedFS OSS `weed admin` only supports local login, so SSO is delivered
# via Authentik forward-auth (same as the in-cluster s3-admin console).
#
# This helper runs early in the wizard (during configure-backup-storage) where
# Authentik/NetBird/Argo CD may not exist yet; it skips cleanly when any
# prerequisite is missing so the step never fails on this.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

: "${TWINBOX_CLUSTER_ID:?missing TWINBOX_CLUSTER_ID}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${BACKUP_S3_PROFILE:?missing BACKUP_S3_PROFILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

BACKUP_S3_APP_MANIFEST_PATH="${BACKUP_S3_APP_MANIFEST_PATH:-$WORKSPACE_ROOT/gitops/apps/backup-s3.yaml}"
BACKUP_S3_PLATFORM_DIR="${BACKUP_S3_PLATFORM_DIR:-$WORKSPACE_ROOT/gitops/platform-apps/backup-s3}"
BACKUP_S3_NAMESPACE="${BACKUP_S3_NAMESPACE:-backup-s3}"
BACKUP_S3_APPLICATION_SLUG="${BACKUP_S3_APPLICATION_SLUG:-backup-s3}"

# --- 0. Resilient prerequisite checks ---
[[ -s "$BACKUP_S3_PROFILE" ]] || { log "No backup S3 profile; skipping publication"; exit 0; }
[[ "$(jq -r '.mode // empty' "$BACKUP_S3_PROFILE")" == "managed-seaweedfs" ]] || { log "Backup storage is not managed SeaweedFS; skipping publication"; exit 0; }
backup_s3_ip="$(jq -r '.vm.ip_address // empty' "$BACKUP_S3_PROFILE")"
[[ -n "$backup_s3_ip" ]] || { log "Backup S3 VM IP not set; skipping publication"; exit 0; }

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl not available; skipping backup S3 publication (re-run after the cluster and identity stack are ready)"
  exit 0
fi
resolve_kubeconfig_file() {
  local candidate=""
  if [[ -n "${KUBECONFIG_FILE:-}" && -f "${KUBECONFIG_FILE:-}" ]]; then
    printf '%s\n' "$KUBECONFIG_FILE"
    return 0
  fi
  for candidate in /home/twinbox/.kube/config "${HOME:-}/.kube/config"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
if ! KUBECONFIG_FILE="$(resolve_kubeconfig_file)"; then
  log "No kubeconfig found; skipping backup S3 publication (re-run after the cluster is attached)"
  exit 0
fi
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
[[ -n "$cluster_dns_domain" ]] || { log "No cluster DNS domain set; skipping backup S3 publication"; exit 0; }
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || { log "Could not determine public zone; skipping backup S3 publication"; exit 0; }

backup_s3_host="https://backup-s3.${public_zone_name}"

if [[ -z "${AUTHENTIK_AUTOMATION_TOKEN:-}" ]] && ! openbao_read_global_secret_json authentik >/dev/null 2>&1; then
  log "Authentik not available yet; skipping backup S3 publication (re-run after the identity stack is ready)"
  exit 0
fi

find_proxy_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/proxy/?page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // .uuid // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local tmp_file http_status

  tmp_file="$(mktemp)"
  http_status="$(
    curl -sS \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Accept: application/json" \
      -o "$tmp_file" \
      -w '%{http_code}' \
      "${AUTHENTIK_API_BASE}/core/applications/${application_slug}/" 2>/dev/null || true
  )"
  if [[ "$http_status" =~ ^2 ]]; then
    cat "$tmp_file"
  fi
  rm -f "$tmp_file"
}

find_policy_binding_pk() {
  local target_uuid="$1"
  local group_id="$2"
  local response

  response="$(authentik_api_get "/policies/bindings/?page_size=200")"
  jq -r \
    --arg target_uuid "$target_uuid" \
    --arg group_id "$group_id" \
    '.results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // empty' <<<"$response" | head -n1
}

extract_authentik_identifier() {
  local payload="${1:-}"

  [[ -n "$payload" ]] || return 0
  jq -er '.pk // .uuid // .id // empty' <<<"$payload" 2>/dev/null || true
}

create_or_update_proxy_provider() {
  local provider_name="$1"
  local application_slug="$2"
  local provider_payload="$3"
  local existing_pk response_file http_status response_json

  existing_pk="$(find_proxy_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik proxy provider for ${provider_name} (provider=${existing_pk})"
    authentik_api_write PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" >/dev/null
    AUTHENTIK_RESOURCE_ID="$existing_pk"
    return 0
  fi

  log "Creating Authentik proxy provider for ${provider_name}"
  response_file="$(mktemp)"
  http_status="$(
    curl -sS \
      -X POST \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      --data "$provider_payload" \
      -o "$response_file" \
      -w '%{http_code}' \
      "${AUTHENTIK_API_BASE}/providers/proxy/"
  )" || http_status="000"

  response_json="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  if [[ "$http_status" =~ ^2 ]]; then
    existing_pk="$(extract_authentik_identifier "$response_json")"
    if [[ -n "$existing_pk" ]]; then
      AUTHENTIK_RESOURCE_ID="$existing_pk"
      return 0
    fi
  fi

  existing_pk="$(find_proxy_provider_pk_by_name "$provider_name")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose a provider ID for ${provider_name}"

  log "Recovering Authentik proxy provider for ${provider_name} after create failure (provider=${existing_pk})"
  authentik_api_write PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" >/dev/null
  AUTHENTIK_RESOURCE_ID="$existing_pk"
}

create_or_update_application() {
  local application_slug="$1"
  local application_name="$2"
  local application_payload="$3"
  local existing_json existing_pk response_file http_status response_json created_pk

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik application for ${application_name} (application=${existing_pk})"
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    AUTHENTIK_RESOURCE_ID="$existing_pk"
    return 0
  fi

  log "Creating Authentik application for ${application_name}"
  response_file="$(mktemp)"
  http_status="$(
    curl -sS \
      -X POST \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      --data "$application_payload" \
      -o "$response_file" \
      -w '%{http_code}' \
      "${AUTHENTIK_API_BASE}/core/applications/"
  )" || http_status="000"

  response_json="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  if [[ "$http_status" =~ ^2 ]]; then
    created_pk="$(extract_authentik_identifier "$response_json")"
    if [[ -n "$created_pk" ]]; then
      AUTHENTIK_RESOURCE_ID="$created_pk"
      return 0
    fi
  fi

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose an application ID for ${application_name}"

  log "Recovering Authentik application for ${application_name} after create failure (application=${existing_pk})"
  authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
  AUTHENTIK_RESOURCE_ID="$existing_pk"
}

ensure_group_binding() {
  local target_uuid="$1"
  local group_id="$2"
  local binding_payload existing_pk

  binding_payload="$(
    jq -n \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
  )"

  existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik admins binding for ${BACKUP_S3_APPLICATION_SLUG} (binding=${existing_pk})"
    authentik_api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  log "Creating Authentik admins binding for ${BACKUP_S3_APPLICATION_SLUG}"
  authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

# --- 1. Deploy the backup-s3 Argo CD app ---
log "Applying backup-s3 Argo CD application (zone=${public_zone_name})"
backup_s3_app_rendered="$(mktemp "${TMPDIR:-/tmp}/backup-s3-application-XXXXXX")"
trap 'rm -f "$backup_s3_app_rendered"' EXIT
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$BACKUP_S3_APP_MANIFEST_PATH" >"$backup_s3_app_rendered"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$backup_s3_app_rendered" \
  --application "backup-s3"

log "Waiting for backup-s3 IngressRoutes"
for attempt in $(seq 1 90); do
  if kubectl -n "$BACKUP_S3_NAMESPACE" get ingressroute backup-s3 >/dev/null 2>&1 \
    && kubectl -n "$BACKUP_S3_NAMESPACE" get ingressroute backup-s3-netbird >/dev/null 2>&1 \
    && kubectl -n "$BACKUP_S3_NAMESPACE" get ingressroute backup-s3-authentik-callback-netbird >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -lt 90 ]] || fail "backup-s3 IngressRoutes did not appear in ${BACKUP_S3_NAMESPACE}"
  sleep 5
done

# --- 2. Apply runtime Endpoints pointing at the backup S3 VM ---
log "Applying backup-s3 Endpoints (ip=${backup_s3_ip})"
backup_s3_endpoints_rendered="$(mktemp "${TMPDIR:-/tmp}/backup-s3-endpoints-XXXXXX")"
trap 'rm -f "$backup_s3_app_rendered" "$backup_s3_endpoints_rendered"' EXIT
sed "s/__BACKUP_S3_HOST_IP__/${backup_s3_ip}/g" "$BACKUP_S3_PLATFORM_DIR/endpoints.yaml" >"$backup_s3_endpoints_rendered"
kubectl apply -f "$backup_s3_endpoints_rendered" >/dev/null
endpoint_ready="$(kubectl -n "$BACKUP_S3_NAMESPACE" get endpoints backup-s3 -o json \
  | jq -r '([.subsets[]?.addresses[]?] | length) as $addresses | ([.subsets[]?.ports[]?] | length) as $ports | if $addresses > 0 and $ports > 0 then "ready" else "empty" end')"
[[ "$endpoint_ready" == "ready" ]] || fail "backup-s3 Endpoints have no ready addresses or ports after apply"

# --- 3. Authentik forward-auth provider + application (admins only) ---
authentik_ensure_token
authentik_setup_forward

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

provider_payload="$(
  jq -n \
    --arg name "SeaweedFS Backup S3 Admin" \
    --arg external_host "$backup_s3_host" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    '{
      name: $name,
      external_host: $external_host,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      mode: "forward_single"
    }'
)"

log "Provisioning Authentik forward-auth provider for backup S3 admin"
AUTHENTIK_RESOURCE_ID=""
create_or_update_proxy_provider "SeaweedFS Backup S3 Admin" "$BACKUP_S3_APPLICATION_SLUG" "$provider_payload"
provider_pk="$AUTHENTIK_RESOURCE_ID"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for the backup S3 admin"

application_payload="$(
  jq -n \
    --arg name "SeaweedFS Backup S3 Admin" \
    --arg slug "$BACKUP_S3_APPLICATION_SLUG" \
    --arg launch_url "$backup_s3_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
AUTHENTIK_RESOURCE_ID=""
create_or_update_application "$BACKUP_S3_APPLICATION_SLUG" "SeaweedFS Backup S3 Admin" "$application_payload"
application_pk="$AUTHENTIK_RESOURCE_ID"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for the backup S3 admin"

application_json="$(find_application_json_by_slug "$BACKUP_S3_APPLICATION_SLUG")"
application_uuid="$(extract_authentik_identifier "$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for the backup S3 admin"
ensure_group_binding "$application_uuid" "$admins_group_id"

# Attach the forward-auth provider to the embedded Authentik outpost
outpost_json="$(authentik_api_get "/outposts/instances/?page_size=100")"
outpost_id="$(printf '%s' "$outpost_json" | jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' | head -n1)"
[[ -n "$outpost_id" && "$outpost_id" != "null" ]] || fail "Could not find the embedded Authentik outpost"
current_providers="$(printf '%s' "$outpost_json" | jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []')"
updated_providers="$(printf '%s' "$current_providers" | jq -c --arg provider_pk "$provider_pk" 'map(tostring) + [$provider_pk] | unique')"
if [[ "$current_providers" != "$updated_providers" ]]; then
  log "Attaching backup S3 admin proxy provider to the embedded Authentik outpost"
  authentik_api_write PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
else
  log "Backup S3 admin proxy provider is already attached to the embedded outpost"
fi

authentik_teardown_forward

# --- 4. Register the NetBird reverse proxy service ---
log "Registering NetBird reverse proxy service for backup S3 admin"
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "backup-s3" \
  --service-domain "backup-s3.${public_zone_name}" \
  --service-path /

log "Backup S3 admin published at ${backup_s3_host}"