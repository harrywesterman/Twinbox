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

CODER_HOST="https://coder.${public_zone_name}"
CODER_REDIRECT_URI="${CODER_HOST}/oauth/callback"

coder_db_username="coder"
coder_db_password="$(openssl rand -hex 24)"
coder_oauth_client_id="$(openssl rand -hex 16)"
coder_oauth_client_secret="$(openssl rand -hex 24)"
coder_database_url="postgres://${coder_db_username}:${coder_db_password}@coder-db-pooler-rw-session.databases.svc.cluster.local:5432/coder"
coder_oidc_issuer="https://authentik.${public_zone_name}/application/o/coder/"

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

  [[ -n "$existing_db_username" ]] && coder_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && coder_db_password="$existing_db_password"
  [[ -n "$existing_database_url" ]] && coder_database_url="$existing_database_url"
  [[ -n "$existing_oauth_client_id" ]] && coder_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && coder_oauth_client_secret="$existing_oauth_client_secret"
fi

coder_secret_file="$(mktemp "${TMPDIR:-/tmp}/coder-bootstrap-XXXXXX")"
coder_oidc_file="$(mktemp "${TMPDIR:-/tmp}/coder-oidc-XXXXXX")"
coder_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/coder-application-XXXXXX")"
trap 'rm -f "$coder_secret_file" "$coder_oidc_file" "$coder_rendered_manifest"' EXIT

jq -n \
  --arg CODER_POSTGRESQL__USERNAME "$coder_db_username" \
  --arg CODER_POSTGRESQL__PASSWORD "$coder_db_password" \
  --arg DATABASE_URL "$coder_database_url" \
  --arg CODER_OIDC_CLIENT_ID "$coder_oauth_client_id" \
  --arg CODER_OIDC_CLIENT_SECRET "$coder_oauth_client_secret" \
  '{
    CODER_POSTGRESQL__USERNAME: $CODER_POSTGRESQL__USERNAME,
    CODER_POSTGRESQL__PASSWORD: $CODER_POSTGRESQL__PASSWORD,
    DATABASE_URL: $DATABASE_URL,
    CODER_OIDC_CLIENT_ID: $CODER_OIDC_CLIENT_ID,
    CODER_OIDC_CLIENT_SECRET: $CODER_OIDC_CLIENT_SECRET
  }' >"$coder_secret_file"

log "Writing Coder bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "coder" \
  --json-file "$coder_secret_file" \
  --required-keys "CODER_POSTGRESQL__USERNAME,CODER_POSTGRESQL__PASSWORD,DATABASE_URL,CODER_OIDC_CLIENT_ID,CODER_OIDC_CLIENT_SECRET"

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

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "coder" \
  --host "coder-db-pooler-rw-session.databases.svc.cluster.local"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "coder" \
    --arg public_url "$CODER_HOST" \
    --arg database "coder-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "coder" \
  --service-domain "coder.${public_zone_name}" \
  --service-path /

log "Pushing Twinbox Coder template..."
export KUBECONFIG="$KUBECONFIG_FILE"
export CODER_URL="https://coder.${public_zone_name}"
if bash "$WORKSPACE_ROOT/scripts/manager/push-coder-template.sh"; then
  log "Coder template pushed successfully"
else
  log "Template push skipped or failed (non-fatal). Push manually after Coder is ready:"
  log "  export CODER_SESSION_TOKEN=<your-token>"
  log "  bash $WORKSPACE_ROOT/scripts/manager/push-coder-template.sh"
fi
