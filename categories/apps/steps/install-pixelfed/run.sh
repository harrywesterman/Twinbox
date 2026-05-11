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

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?name=$(printf '%s' "$provider_name" | jq -sRr @uri)&page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response

  response="$(authentik_api_get "/core/applications/?slug=$(printf '%s' "$application_slug" | jq -sRr @uri)")"
  local match
  match="$(jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1)"
  if [[ -n "$match" ]]; then
    printf '%s\n' "$match"
    return 0
  fi

  # Fallback: direct lookup by slug (Authentik list filter can be unreliable)
  response="$(authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true)"
  if [[ -n "$response" ]] && jq -e --arg slug "$application_slug" '(.slug // "") == $slug' >/dev/null 2>&1 <<<"$response"; then
    printf '%s\n' "$response"
    return 0
  fi

  return 0
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Pixelfed")"
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

  existing_json="$(find_application_json_by_slug "$pixelfed_sso_application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${pixelfed_sso_application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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
    authentik_api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
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
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

pixelfed_db_username="pixelfed"
pixelfed_db_password="$(openssl rand -hex 24)"
pixelfed_app_key="base64:$(openssl rand -base64 32 | tr -d '\n')"

existing_pixelfed_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_pixelfed_secret_json="$(openbao_read_global_secret_json pixelfed 2>/dev/null || true)"
fi

if [[ -n "$existing_pixelfed_secret_json" ]]; then
  existing_app_key="$(jq -r '.APP_KEY // empty' <<<"$existing_pixelfed_secret_json" || true)"
  existing_db_username="$(jq -r '.PIXELFED_POSTGRESQL__USERNAME // empty' <<<"$existing_pixelfed_secret_json" || true)"
  existing_db_password="$(jq -r '.PIXELFED_POSTGRESQL__PASSWORD // empty' <<<"$existing_pixelfed_secret_json" || true)"

  [[ -n "$existing_app_key" ]] && pixelfed_app_key="$existing_app_key"
  [[ -n "$existing_db_username" ]] && pixelfed_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && pixelfed_db_password="$existing_db_password"
fi

pixelfed_sso_client_id="$(openssl rand -hex 16)"
pixelfed_sso_client_secret="$(openssl rand -hex 24)"
if [[ -n "$existing_pixelfed_secret_json" ]]; then
  existing_sso_client_id="$(jq -r '.PF_OIDC_CLIENT_ID // empty' <<<"$existing_pixelfed_secret_json")"
  existing_sso_client_secret="$(jq -r '.PF_OIDC_CLIENT_SECRET // empty' <<<"$existing_pixelfed_secret_json")"
  [[ -n "$existing_sso_client_id" ]] && pixelfed_sso_client_id="$existing_sso_client_id"
  [[ -n "$existing_sso_client_secret" ]] && pixelfed_sso_client_secret="$existing_sso_client_secret"
fi
pixelfed_sso_application_slug="pixelfed"
pixelfed_host="https://pixelfed.${public_zone_name}"
pixelfed_sso_redirect_uri="${pixelfed_host}/auth/oidc/callback"

pixelfed_secret_file="$(mktemp "${TMPDIR:-/tmp}/pixelfed-bootstrap-XXXXXX.json")"
pixelfed_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/pixelfed-application-XXXXXX.yaml")"
trap 'rm -f "$pixelfed_secret_file" "$pixelfed_rendered_manifest"' EXIT

log "Provisioning Authentik OIDC client for Pixelfed"
authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
# Authentik OAuth2 endpoints: authorize, token and userinfo are global;
# end-session is per-application.
pixelfed_sso_authorize_url="${AUTHENTIK_HOST%/}/application/o/authorize/"
pixelfed_sso_token_url="${AUTHENTIK_HOST%/}/application/o/token/"
pixelfed_sso_profile_url="${AUTHENTIK_HOST%/}/application/o/userinfo/"
pixelfed_sso_logout_url="${AUTHENTIK_HOST%/}/application/o/${pixelfed_sso_application_slug}/end-session/"

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
admins_group_id="$(authentik_find_group_id "admins")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Pixelfed" \
    --arg client_id "$pixelfed_sso_client_id" \
    --arg client_secret "$pixelfed_sso_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$pixelfed_sso_redirect_uri" \
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
          matching_mode: "strict",
          url: $redirect_uri
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      issuer_mode: "per_provider"
    }'
)"

provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Pixelfed"

application_payload="$(
  jq -n \
    --arg name "Pixelfed" \
    --arg slug "$pixelfed_sso_application_slug" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Pixelfed"

application_json="$(find_application_json_by_slug "$pixelfed_sso_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Pixelfed"
ensure_group_binding "$application_uuid" "$admins_group_id"

jq -n \
  --arg APP_KEY "$pixelfed_app_key" \
  --arg PIXELFED_POSTGRESQL__USERNAME "$pixelfed_db_username" \
  --arg PIXELFED_POSTGRESQL__PASSWORD "$pixelfed_db_password" \
  --arg PF_OIDC_CLIENT_ID "$pixelfed_sso_client_id" \
  --arg PF_OIDC_CLIENT_SECRET "$pixelfed_sso_client_secret" \
  --arg PF_OIDC_AUTHORIZE_URL "$pixelfed_sso_authorize_url" \
  --arg PF_OIDC_TOKEN_URL "$pixelfed_sso_token_url" \
  --arg PF_OIDC_PROFILE_URL "$pixelfed_sso_profile_url" \
  --arg PF_OIDC_LOGOUT_URL "$pixelfed_sso_logout_url" \
  '{
    APP_KEY: $APP_KEY,
    PIXELFED_POSTGRESQL__USERNAME: $PIXELFED_POSTGRESQL__USERNAME,
    PIXELFED_POSTGRESQL__PASSWORD: $PIXELFED_POSTGRESQL__PASSWORD,
    PF_OIDC_CLIENT_ID: $PF_OIDC_CLIENT_ID,
    PF_OIDC_CLIENT_SECRET: $PF_OIDC_CLIENT_SECRET,
    PF_OIDC_AUTHORIZE_URL: $PF_OIDC_AUTHORIZE_URL,
    PF_OIDC_TOKEN_URL: $PF_OIDC_TOKEN_URL,
    PF_OIDC_PROFILE_URL: $PF_OIDC_PROFILE_URL,
    PF_OIDC_LOGOUT_URL: $PF_OIDC_LOGOUT_URL
  }' >"$pixelfed_secret_file"

log "Writing Pixelfed bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "pixelfed" \
  --json-file "$pixelfed_secret_file" \
  --required-keys "APP_KEY,PIXELFED_POSTGRESQL__USERNAME,PIXELFED_POSTGRESQL__PASSWORD,PF_OIDC_CLIENT_ID,PF_OIDC_CLIENT_SECRET,PF_OIDC_AUTHORIZE_URL,PF_OIDC_TOKEN_URL,PF_OIDC_PROFILE_URL,PF_OIDC_LOGOUT_URL"

log "Applying Pixelfed database manifests"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/cluster.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/pooler-ro.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/pooler-rw.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/pooler-rw-session.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/pixelfed/scheduled-backup.yaml"

wait_for_resource_ready "databases" "externalsecret/pixelfed-db-credentials" "Ready" "Pixelfed database ExternalSecret"
wait_for_resource_ready "databases" "cluster/pixelfed-db" "Ready" "Pixelfed CloudNativePG cluster"
wait_for_resource_ready "databases" "deployment/pixelfed-db-pooler-ro" "Available" "Pixelfed read-only pooler"
wait_for_resource_ready "databases" "deployment/pixelfed-db-pooler-rw" "Available" "Pixelfed read-write pooler"
wait_for_resource_ready "databases" "deployment/pixelfed-db-pooler-rw-session" "Available" "Pixelfed session pooler"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "pixelfed" \
  --host "pixelfed-db-pooler-rw-session.databases.svc.cluster.local"

log "Applying Pixelfed Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/pixelfed.yaml" >"$pixelfed_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$pixelfed_rendered_manifest" \
  --application "pixelfed" \
  --destination-namespace "pixelfed"

kubectl -n pixelfed rollout status deployment/pixelfed --timeout=10m >/dev/null

log "Bootstrapping Pixelfed federation and OAuth keys"
kubectl -n pixelfed exec deployment/pixelfed -- php artisan instance:actor

if ! kubectl -n pixelfed exec deployment/pixelfed -- test -f /var/www/html/storage/oauth-private.key >/dev/null 2>&1; then
  kubectl -n pixelfed exec deployment/pixelfed -- php artisan passport:keys --force
fi

kubectl -n pixelfed exec deployment/pixelfed -- php artisan config:cache
kubectl -n pixelfed exec deployment/pixelfed -- php artisan route:cache
kubectl -n pixelfed exec deployment/pixelfed -- php artisan view:cache

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "pixelfed" \
    --arg public_url "https://pixelfed.${public_zone_name}" \
    --arg database "pixelfed-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi
