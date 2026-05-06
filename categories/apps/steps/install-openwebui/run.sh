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

wait_for_resources_ready() {
  local namespace="$1"
  local kind="$2"
  local condition="$3"
  local label="$4"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" get "$kind" -o name 2>/dev/null | grep -q .; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$kind" --all --timeout=5s >/dev/null 2>&1; then
        log "${label} resources are ready"
        return 0
      fi

      log "Waiting for ${label} resources to become ready"
    else
      log "Waiting for ${label} resources to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} resources did not become ready after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
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

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

authentik_ensure_token
authentik_setup_forward

openwebui_db_username="openwebui"
openwebui_db_password="$(openssl rand -hex 24)"
webui_secret_key="$(openssl rand -hex 32)"
oauth_session_token_encryption_key="$(openssl rand -hex 32)"
oauth_client_info_encryption_key="$(openssl rand -hex 32)"
oauth_client_id="$(openssl rand -hex 16)"
oauth_client_secret="$(openssl rand -hex 32)"

existing_openwebui_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_openwebui_secret_json="$(openbao_read_global_secret_json openwebui 2>/dev/null || true)"
fi

if [[ -n "$existing_openwebui_secret_json" ]]; then
  existing_db_username="$(jq -r '.OPENWEBUI_POSTGRESQL__USERNAME // empty' <<<"$existing_openwebui_secret_json" || true)"
  existing_db_password="$(jq -r '.OPENWEBUI_POSTGRESQL__PASSWORD // empty' <<<"$existing_openwebui_secret_json" || true)"
  existing_webui_secret_key="$(jq -r '.WEBUI_SECRET_KEY // empty' <<<"$existing_openwebui_secret_json" || true)"
  existing_oauth_session_token_encryption_key="$(jq -r '.OAUTH_SESSION_TOKEN_ENCRYPTION_KEY // empty' <<<"$existing_openwebui_secret_json" || true)"
  existing_oauth_client_info_encryption_key="$(jq -r '.OAUTH_CLIENT_INFO_ENCRYPTION_KEY // empty' <<<"$existing_openwebui_secret_json" || true)"
  existing_oauth_client_id="$(jq -r '.OAUTH_CLIENT_ID // empty' <<<"$existing_openwebui_secret_json" || true)"
  existing_oauth_client_secret="$(jq -r '.OAUTH_CLIENT_SECRET // empty' <<<"$existing_openwebui_secret_json" || true)"

  [[ -n "$existing_db_username" ]] && openwebui_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && openwebui_db_password="$existing_db_password"
  [[ -n "$existing_webui_secret_key" ]] && webui_secret_key="$existing_webui_secret_key"
  [[ -n "$existing_oauth_session_token_encryption_key" ]] && oauth_session_token_encryption_key="$existing_oauth_session_token_encryption_key"
  [[ -n "$existing_oauth_client_info_encryption_key" ]] && oauth_client_info_encryption_key="$existing_oauth_client_info_encryption_key"
  [[ -n "$existing_oauth_client_id" ]] && oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && oauth_client_secret="$existing_oauth_client_secret"
fi

openwebui_database_url="postgresql://${openwebui_db_username}:${openwebui_db_password}@openwebui-db-pooler-rw-session.databases.svc.cluster.local:5432/openwebui"

openwebui_secret_file="$(mktemp "${TMPDIR:-/tmp}/openwebui-bootstrap.XXXXXX.json")"
openwebui_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/openwebui-application.XXXXXX.yaml")"
trap 'rm -f "$openwebui_secret_file" "$openwebui_rendered_app_manifest"' EXIT

jq -n \
  --arg OPENWEBUI_POSTGRESQL__USERNAME "$openwebui_db_username" \
  --arg OPENWEBUI_POSTGRESQL__PASSWORD "$openwebui_db_password" \
  --arg OPENWEBUI_DATABASE_URL "$openwebui_database_url" \
  --arg WEBUI_SECRET_KEY "$webui_secret_key" \
  --arg OAUTH_SESSION_TOKEN_ENCRYPTION_KEY "$oauth_session_token_encryption_key" \
  --arg OAUTH_CLIENT_INFO_ENCRYPTION_KEY "$oauth_client_info_encryption_key" \
  --arg OAUTH_CLIENT_ID "$oauth_client_id" \
  --arg OAUTH_CLIENT_SECRET "$oauth_client_secret" \
  '{
    OPENWEBUI_POSTGRESQL__USERNAME: $OPENWEBUI_POSTGRESQL__USERNAME,
    OPENWEBUI_POSTGRESQL__PASSWORD: $OPENWEBUI_POSTGRESQL__PASSWORD,
    OPENWEBUI_DATABASE_URL: $OPENWEBUI_DATABASE_URL,
    WEBUI_SECRET_KEY: $WEBUI_SECRET_KEY,
    OAUTH_SESSION_TOKEN_ENCRYPTION_KEY: $OAUTH_SESSION_TOKEN_ENCRYPTION_KEY,
    OAUTH_CLIENT_INFO_ENCRYPTION_KEY: $OAUTH_CLIENT_INFO_ENCRYPTION_KEY,
    OAUTH_CLIENT_ID: $OAUTH_CLIENT_ID,
    OAUTH_CLIENT_SECRET: $OAUTH_CLIENT_SECRET
  }' >"$openwebui_secret_file"

log "Writing Open WebUI bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "openwebui" \
  --json-file "$openwebui_secret_file" \
  --required-keys "OPENWEBUI_POSTGRESQL__USERNAME,OPENWEBUI_POSTGRESQL__PASSWORD,OPENWEBUI_DATABASE_URL,WEBUI_SECRET_KEY,OAUTH_SESSION_TOKEN_ENCRYPTION_KEY,OAUTH_CLIENT_INFO_ENCRYPTION_KEY,OAUTH_CLIENT_ID,OAUTH_CLIENT_SECRET"

resolve_scope_mapping_id() {
  authentik_resolve_scope_mapping_id "$1"
}

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"

openwebui_provider_name="Open WebUI"
openwebui_application_slug="openwebui"
openwebui_provider_payload="$(
  jq -n \
    --arg name "$openwebui_provider_name" \
    --arg slug "$openwebui_application_slug" \
    --arg client_id "$oauth_client_id" \
    --arg client_secret "$oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "https://openwebui.${public_zone_name}/oauth/oidc/callback" \
    --argjson property_mappings "$(jq -cn --arg openid "$openid_mapping_id" --arg email "$email_mapping_id" --arg profile "$profile_mapping_id" '[$openid, $email, $profile]')" \
    '{
      name: $name,
      slug: $slug,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      client_id: $client_id,
      client_secret: $client_secret,
      client_type: "confidential",
      issuer_mode: "per_provider",
      signing_key: $signing_key,
      property_mappings: $property_mappings,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $redirect_uri
        }
      ],
      include_claims_in_id_token: true
    }'
)"

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  authentik_api_get "/providers/oauth2/?page_size=200" \
    | jq -r --arg provider_name "$provider_name" '.results[]? | select((.name // "") == $provider_name) | .pk // .id // empty' \
    | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  authentik_api_get "/core/applications/?page_size=200" \
    | jq -c --arg application_slug "$application_slug" '.results[]? | select((.slug // "") == $application_slug)' \
    | head -n1
}

create_or_update_provider() {
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi

  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

provider_pk="$(create_or_update_provider "$openwebui_provider_name" "$openwebui_provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return an OAuth provider ID for Open WebUI"

openwebui_application_payload="$(
  jq -n \
    --arg name "Open WebUI" \
    --arg slug "$openwebui_application_slug" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "https://openwebui.${public_zone_name}" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber),
      meta_launch_url: $launch_url
    }'
)"

application_pk="$(create_or_update_application "$openwebui_application_slug" "$openwebui_application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Open WebUI"

log "Applying Open WebUI application namespace and ExternalSecret"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/openwebui/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/openwebui/externalsecret.yaml"
wait_for_resources_ready "openwebui" "externalsecret" "Ready" "Open WebUI application"

log "Applying Open WebUI database manifests"
kubectl apply -k "$WORKSPACE_ROOT/gitops/databases/openwebui"
wait_for_resources_ready "databases" "externalsecret" "Ready" "Open WebUI database"
wait_for_resources_ready "databases" "cluster" "Ready" "Open WebUI CloudNativePG cluster"
kubectl -n databases wait --for=condition=Available deployment/openwebui-db-pooler-ro deployment/openwebui-db-pooler-rw deployment/openwebui-db-pooler-rw-session --timeout=10m >/dev/null 2>&1 \
  || fail "Open WebUI pooler deployments did not become available"
log "Open WebUI pooler deployments are ready"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "openwebui" \
  --host "openwebui-db-pooler-rw-session.databases.svc.cluster.local"

log "Applying Open WebUI Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$WORKSPACE_ROOT/gitops/apps/openwebui.yaml" >"$openwebui_rendered_app_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$openwebui_rendered_app_manifest" \
  --application "openwebui"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "openwebui" \
    --arg manifest_path "$WORKSPACE_ROOT/gitops/apps/openwebui.yaml" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
