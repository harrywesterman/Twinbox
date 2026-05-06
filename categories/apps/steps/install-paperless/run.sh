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
  local response

  response="$(authentik_api_get "/core/applications/?page_size=100")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Paperless-ngx")"
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

  existing_json="$(find_application_json_by_slug "paperless" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/paperless/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
PAPERLESS_HOST="https://paperless.${public_zone_name}"
PAPERLESS_OIDC_REDIRECT_URI="${PAPERLESS_HOST}/accounts/oidc/authentik/login/callback/"

paperless_secret_key="$(openssl rand -hex 32)"
paperless_admin_user="admin"
paperless_admin_password="$(openssl rand -hex 24)"
paperless_admin_mail="admin@${public_zone_name}"
paperless_db_user="paperless"
paperless_db_password="$(openssl rand -hex 24)"
paperless_oauth_client_id="$(openssl rand -hex 16)"
paperless_oauth_client_secret="$(openssl rand -hex 32)"

existing_paperless_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_paperless_secret_json="$(openbao_read_global_secret_json paperless 2>/dev/null || true)"
fi

if [[ -n "$existing_paperless_secret_json" ]]; then
  existing_secret_key="$(jq -r '.PAPERLESS_SECRET_KEY // empty' <<<"$existing_paperless_secret_json")"
  existing_admin_user="$(jq -r '.PAPERLESS_ADMIN_USER // empty' <<<"$existing_paperless_secret_json")"
  existing_admin_password="$(jq -r '.PAPERLESS_ADMIN_PASSWORD // empty' <<<"$existing_paperless_secret_json")"
  existing_admin_mail="$(jq -r '.PAPERLESS_ADMIN_MAIL // empty' <<<"$existing_paperless_secret_json")"
  existing_db_user="$(jq -r '.PAPERLESS_DBUSER // empty' <<<"$existing_paperless_secret_json")"
  existing_db_password="$(jq -r '.PAPERLESS_DBPASS // empty' <<<"$existing_paperless_secret_json")"
  existing_oauth_client_id="$(jq -r '.PAPERLESS_OIDC_CLIENT_ID // empty' <<<"$existing_paperless_secret_json")"
  existing_oauth_client_secret="$(jq -r '.PAPERLESS_OIDC_CLIENT_SECRET // empty' <<<"$existing_paperless_secret_json")"

  [[ -n "$existing_secret_key" ]] && paperless_secret_key="$existing_secret_key"
  [[ -n "$existing_admin_user" ]] && paperless_admin_user="$existing_admin_user"
  [[ -n "$existing_admin_password" ]] && paperless_admin_password="$existing_admin_password"
  [[ -n "$existing_admin_mail" ]] && paperless_admin_mail="$existing_admin_mail"
  [[ -n "$existing_db_user" ]] && paperless_db_user="$existing_db_user"
  [[ -n "$existing_db_password" ]] && paperless_db_password="$existing_db_password"
  [[ -n "$existing_oauth_client_id" ]] && paperless_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && paperless_oauth_client_secret="$existing_oauth_client_secret"
fi

paperless_socialaccount_providers="$(
  jq -cn \
    --arg client_id "$paperless_oauth_client_id" \
    --arg client_secret "$paperless_oauth_client_secret" \
    --arg server_url "${AUTHENTIK_HOST%/}/application/o/paperless/.well-known/openid-configuration" \
    '{
      openid_connect: {
        APPS: [
          {
            provider_id: "authentik",
            name: "Authentik",
            client_id: $client_id,
            secret: $client_secret,
            settings: {
              server_url: $server_url
            }
          }
        ],
        SCOPE: ["openid", "profile", "email"]
      }
    }'
)"

paperless_secret_file="$(mktemp "${TMPDIR:-/tmp}/paperless-bootstrap.XXXXXX.json")"
paperless_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/paperless-application.XXXXXX.yaml")"
paperless_rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/paperless-ingressroute.XXXXXX.yaml")"
trap 'rm -f "$paperless_secret_file" "$paperless_rendered_app_manifest" "$paperless_rendered_ingressroute"' EXIT

jq -n \
  --arg PAPERLESS_SECRET_KEY "$paperless_secret_key" \
  --arg PAPERLESS_ADMIN_USER "$paperless_admin_user" \
  --arg PAPERLESS_ADMIN_PASSWORD "$paperless_admin_password" \
  --arg PAPERLESS_ADMIN_MAIL "$paperless_admin_mail" \
  --arg PAPERLESS_DBUSER "$paperless_db_user" \
  --arg PAPERLESS_DBPASS "$paperless_db_password" \
  --arg PAPERLESS_OIDC_CLIENT_ID "$paperless_oauth_client_id" \
  --arg PAPERLESS_OIDC_CLIENT_SECRET "$paperless_oauth_client_secret" \
  --arg PAPERLESS_SOCIALACCOUNT_PROVIDERS "$paperless_socialaccount_providers" \
  '{
    PAPERLESS_SECRET_KEY: $PAPERLESS_SECRET_KEY,
    PAPERLESS_ADMIN_USER: $PAPERLESS_ADMIN_USER,
    PAPERLESS_ADMIN_PASSWORD: $PAPERLESS_ADMIN_PASSWORD,
    PAPERLESS_ADMIN_MAIL: $PAPERLESS_ADMIN_MAIL,
    PAPERLESS_DBUSER: $PAPERLESS_DBUSER,
    PAPERLESS_DBPASS: $PAPERLESS_DBPASS,
    PAPERLESS_OIDC_CLIENT_ID: $PAPERLESS_OIDC_CLIENT_ID,
    PAPERLESS_OIDC_CLIENT_SECRET: $PAPERLESS_OIDC_CLIENT_SECRET,
    PAPERLESS_SOCIALACCOUNT_PROVIDERS: $PAPERLESS_SOCIALACCOUNT_PROVIDERS
  }' >"$paperless_secret_file"

log "Writing Paperless-ngx bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "paperless" \
  --json-file "$paperless_secret_file" \
  --required-keys "PAPERLESS_SECRET_KEY,PAPERLESS_ADMIN_USER,PAPERLESS_ADMIN_PASSWORD,PAPERLESS_ADMIN_MAIL,PAPERLESS_DBUSER,PAPERLESS_DBPASS,PAPERLESS_OIDC_CLIENT_ID,PAPERLESS_OIDC_CLIENT_SECRET,PAPERLESS_SOCIALACCOUNT_PROVIDERS"

log "Provisioning Authentik OIDC client for Paperless-ngx"
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
    --arg name "Paperless-ngx" \
    --arg client_id "$paperless_oauth_client_id" \
    --arg client_secret "$paperless_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$PAPERLESS_OIDC_REDIRECT_URI" \
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
      issuer_mode: "per_provider"
    }'
)"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Paperless-ngx"

application_payload="$(
  jq -n \
    --arg name "Paperless-ngx" \
    --arg slug "paperless" \
    --arg launch_url "$PAPERLESS_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Paperless-ngx"

paperless_platform_dir="$WORKSPACE_ROOT/gitops/platform-apps/paperless"
paperless_app_manifest="$WORKSPACE_ROOT/gitops/apps/paperless.yaml"

log "Applying Paperless-ngx namespace and secret resources"
kubectl apply -f "$paperless_platform_dir/namespace.yaml"
kubectl apply -f "$paperless_platform_dir/externalsecret.yaml"
render_template \
  "$paperless_platform_dir/ingressroute.yaml" \
  "$paperless_rendered_ingressroute" \
  "__ZONE_NAME__=$public_zone_name"
kubectl apply -f "$paperless_rendered_ingressroute"

wait_for_resources_ready "paperless" "externalsecret" "Ready" "Paperless-ngx ExternalSecret"

log "Applying Paperless-ngx database manifests"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/paperless/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/paperless/cluster.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/paperless/pooler-ro.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/paperless/pooler-rw.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/paperless/scheduled-backup.yaml"

wait_for_resources_ready "databases" "externalsecret" "Ready" "Paperless-ngx database ExternalSecret"
wait_for_resources_ready "databases" "cluster" "Ready" "Paperless-ngx CloudNativePG cluster"
wait_for_resources_ready "databases" "deployment" "Available" "Paperless-ngx pooler deployment"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "paperless" \
  --host "paperless-db-pooler-rw.databases.svc.cluster.local"

log "Applying Paperless-ngx Argo CD application"
render_template \
  "$paperless_app_manifest" \
  "$paperless_rendered_app_manifest" \
  "__ZONE_NAME__=$public_zone_name"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$paperless_rendered_app_manifest" \
  --application "paperless" \
  --destination-namespace "paperless"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "paperless" \
    --arg public_url "$PAPERLESS_HOST" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url
    }' >"$STEP_RESULT_FILE"
fi
