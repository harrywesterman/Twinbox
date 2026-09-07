#!/usr/bin/env bash
set -euo pipefail

# configure-pbs-publication.sh
# Publishes the Proxmox Backup Server VM behind the Twinbox reverse proxy chain:
#   1. Deploys the PBS Argo CD app (namespace, service, ServersTransport, Traefik IngressRoutes).
#   2. Applies the runtime Endpoints that point at the PBS VM IP.
#   3. Creates an Authentik OAuth2/OIDC provider + application (admins only) for native SSO.
#   4. Configures the PBS OpenID realm over SSH and grants the Admin role to admins.
#   5. Registers the NetBird reverse proxy service pbs.<zone> -> Traefik.
#
# Requires: kubectl, KUBECONFIG_FILE, SSH access to the PBS VM, Authentik API access.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

: "${TWINBOX_CLUSTER_ID:?missing TWINBOX_CLUSTER_ID}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${PBS_IP_ADDRESS:?missing PBS_IP_ADDRESS}"
: "${PBS_SSH_PRIVATE_KEY:?missing PBS_SSH_PRIVATE_KEY}"
: "${PBS_PROFILE:?missing PBS_PROFILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

PBS_APP_MANIFEST_PATH="${PBS_APP_MANIFEST_PATH:-$WORKSPACE_ROOT/gitops/apps/pbs.yaml}"
PBS_PLATFORM_DIR="${PBS_PLATFORM_DIR:-$WORKSPACE_ROOT/gitops/platform-apps/pbs}"
PBS_NAMESPACE="${PBS_NAMESPACE:-pbs}"
PBS_APPLICATION_SLUG="${PBS_APPLICATION_SLUG:-pbs}"
PBS_REALM="${PBS_REALM:-pbs}"

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

  fail "Could not find a usable kubeconfig; expected cluster attachment or /home/twinbox/.kube/config"
}

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true
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

create_or_update_oauth2_provider() {
  local provider_name="$1"
  local application_slug="$2"
  local provider_payload="$3"
  local existing_pk response_file http_status response_json

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik OAuth2 provider for ${provider_name} (provider=${existing_pk})"
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    AUTHENTIK_RESOURCE_ID="$existing_pk"
    return 0
  fi

  log "Creating Authentik OAuth2 provider for ${provider_name}"
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
      "${AUTHENTIK_API_BASE}/providers/oauth2/"
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

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose a provider ID for ${provider_name}"

  log "Recovering Authentik OAuth2 provider for ${provider_name} after create failure (provider=${existing_pk})"
  authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
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
    log "Updating Authentik admins binding for ${PBS_APPLICATION_SLUG} (binding=${existing_pk})"
    authentik_api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  log "Creating Authentik admins binding for ${PBS_APPLICATION_SLUG}"
  authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

pbs_host="https://pbs.${public_zone_name}"
authentik_host="https://authentik.${public_zone_name}"
pbs_oidc_issuer="${authentik_host%/}/application/o/${PBS_APPLICATION_SLUG}/"

# --- 1. Deploy the PBS Argo CD app ---
log "Applying PBS Argo CD application (zone=${public_zone_name})"
pbs_app_rendered="$(mktemp "${TMPDIR:-/tmp}/pbs-application-XXXXXX")"
trap 'rm -f "$pbs_app_rendered"' EXIT
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$PBS_APP_MANIFEST_PATH" >"$pbs_app_rendered"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$pbs_app_rendered" \
  --application "pbs"

log "Waiting for PBS IngressRoutes"
for attempt in $(seq 1 90); do
  if kubectl -n "$PBS_NAMESPACE" get ingressroute pbs >/dev/null 2>&1 \
    && kubectl -n "$PBS_NAMESPACE" get ingressroute pbs-netbird >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -lt 90 ]] || fail "PBS IngressRoutes did not appear in ${PBS_NAMESPACE}"
  sleep 5
done

# --- 2. Apply runtime Endpoints pointing at the PBS VM ---
log "Applying PBS Endpoints (ip=${PBS_IP_ADDRESS})"
pbs_endpoints_rendered="$(mktemp "${TMPDIR:-/tmp}/pbs-endpoints-XXXXXX")"
trap 'rm -f "$pbs_app_rendered" "$pbs_endpoints_rendered"' EXIT
sed "s/__PBS_HOST_IP__/${PBS_IP_ADDRESS}/g" "$PBS_PLATFORM_DIR/endpoints.yaml" >"$pbs_endpoints_rendered"
kubectl apply -f "$pbs_endpoints_rendered" >/dev/null
endpoint_ready="$(kubectl -n "$PBS_NAMESPACE" get endpoints pbs -o json \
  | jq -r '([.subsets[]?.addresses[]?] | length) as $addresses | ([.subsets[]?.ports[]?] | length) as $ports | if $addresses > 0 and $ports > 0 then "ready" else "empty" end')"
[[ "$endpoint_ready" == "ready" ]] || fail "PBS Endpoints have no ready addresses or ports after apply"

# --- 3. Authentik OIDC provider + application (admins only) ---
authentik_ensure_token
authentik_setup_forward

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"
signing_key_id="$(authentik_resolve_signing_key_id)"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"
[[ -n "$openid_mapping_id" && -n "$email_mapping_id" && -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping IDs"

oidc_client_id="$(jq -r '.oidc_client_id // empty' "$PBS_PROFILE" 2>/dev/null || true)"
oidc_client_secret="$(jq -r '.oidc_client_secret // empty' "$PBS_PROFILE" 2>/dev/null || true)"
if [[ -z "$oidc_client_id" || -z "$oidc_client_secret" ]]; then
  oidc_client_id="$(openssl rand -hex 16)"
  oidc_client_secret="$(openssl rand -hex 24)"
fi

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "PBS" \
    --arg client_id "$oidc_client_id" \
    --arg client_secret "$oidc_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$pbs_host" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: [
        {
          matching_mode: "prefix",
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

log "Provisioning Authentik OIDC client for PBS"
AUTHENTIK_RESOURCE_ID=""
create_or_update_oauth2_provider "PBS" "$PBS_APPLICATION_SLUG" "$provider_payload"
provider_pk="$AUTHENTIK_RESOURCE_ID"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for PBS"

application_payload="$(
  jq -n \
    --arg name "PBS" \
    --arg slug "$PBS_APPLICATION_SLUG" \
    --arg launch_url "$pbs_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
AUTHENTIK_RESOURCE_ID=""
create_or_update_application "$PBS_APPLICATION_SLUG" "PBS" "$application_payload"
application_pk="$AUTHENTIK_RESOURCE_ID"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for PBS"

application_json="$(find_application_json_by_slug "$PBS_APPLICATION_SLUG")"
application_uuid="$(extract_authentik_identifier "$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for PBS"
ensure_group_binding "$application_uuid" "$admins_group_id"

admin_usernames="$(authentik_api_get "/core/groups/${admins_group_id}/users/?page_size=100" \
  | jq -r '[.results[]? | .username] | map(select(length > 0)) | unique | join("\n")')"

jq --arg oidc_client_id "$oidc_client_id" --arg oidc_client_secret "$oidc_client_secret" \
  '.oidc_client_id=$oidc_client_id | .oidc_client_secret=$oidc_client_secret' "$PBS_PROFILE" >"${PBS_PROFILE}.tmp"
mv "${PBS_PROFILE}.tmp" "$PBS_PROFILE"; chmod 0600 "$PBS_PROFILE"

# --- 4. Configure the PBS OpenID realm and admin ACLs over SSH ---
ssh_opts=(-i "$PBS_SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
realm_exists="$(
  ssh "${ssh_opts[@]}" "twinbox@${PBS_IP_ADDRESS}" \
    "sudo proxmox-backup-manager openid list --output-format json 2>/dev/null \
       | jq -e 'any(.[]; .realm == \"${PBS_REALM}\")' >/dev/null 2>&1 && echo yes || echo no"
)"
if [[ "$realm_exists" == "yes" ]]; then
  log "Updating PBS OpenID realm '${PBS_REALM}'"
  ssh "${ssh_opts[@]}" "twinbox@${PBS_IP_ADDRESS}" \
    sudo proxmox-backup-manager openid update "$PBS_REALM" \
    --issuer-url "$pbs_oidc_issuer" \
    --client-id "$oidc_client_id" \
    --client-key "$oidc_client_secret" \
    --autocreate 1 \
    --default 1
else
  log "Creating PBS OpenID realm '${PBS_REALM}'"
  ssh "${ssh_opts[@]}" "twinbox@${PBS_IP_ADDRESS}" \
    sudo proxmox-backup-manager openid create "$PBS_REALM" \
    --issuer-url "$pbs_oidc_issuer" \
    --client-id "$oidc_client_id" \
    --client-key "$oidc_client_secret" \
    --username-claim username \
    --autocreate 1 \
    --default 1
fi

granted_admins=0
while IFS= read -r username; do
  [[ -n "$username" ]] || continue
  ssh -n "${ssh_opts[@]}" "twinbox@${PBS_IP_ADDRESS}" \
    "sudo proxmox-backup-manager user create '${username}@${PBS_REALM}' >/dev/null 2>&1 || true"
  ssh -n "${ssh_opts[@]}" "twinbox@${PBS_IP_ADDRESS}" \
    "sudo proxmox-backup-manager acl update / Admin --auth-id '${username}@${PBS_REALM}'"
  granted_admins=$((granted_admins + 1))
  log "Granted PBS Admin role to ${username}@${PBS_REALM}"
done <<<"$admin_usernames"

[[ "$granted_admins" -gt 0 ]] || log "WARNING: No Authentik admins group members were granted PBS Admin ACLs"

authentik_teardown_forward

# --- 5. Register the NetBird reverse proxy service ---
log "Registering NetBird reverse proxy service for PBS"
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "pbs" \
  --service-domain "pbs.${public_zone_name}" \
  --service-path /

log "PBS published at ${pbs_host} (OIDC issuer ${pbs_oidc_issuer})"