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

  existing_pk="$(find_oauth2_provider_pk_by_name "Karakeep")"
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

  existing_json="$(find_application_json_by_slug "karakeep" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/karakeep/" "$application_payload" >/dev/null
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
KARAKEEP_HOST="https://karakeep.${public_zone_name}"
KARAKEEP_REDIRECT_URI="${KARAKEEP_HOST}/api/auth/callback/custom"

karakeep_nextauth_secret="$(openssl rand -hex 32)"
karakeep_meili_master_key="$(openssl rand -hex 24)"
karakeep_oauth_client_id="$(openssl rand -hex 16)"
karakeep_oauth_client_secret="$(openssl rand -hex 24)"

existing_karakeep_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_karakeep_secret_json="$(openbao_read_global_secret_json karakeep 2>/dev/null || true)"
fi

if [[ -n "$existing_karakeep_secret_json" ]]; then
  existing_nextauth_secret="$(jq -r '.KARAKEEP_NEXTAUTH_SECRET // empty' <<<"$existing_karakeep_secret_json")"
  existing_meili_master_key="$(jq -r '.KARAKEEP_MEILI_MASTER_KEY // empty' <<<"$existing_karakeep_secret_json")"
  existing_oauth_client_id="$(jq -r '.KARAKEEP_OAUTH_CLIENT_ID // empty' <<<"$existing_karakeep_secret_json")"
  existing_oauth_client_secret="$(jq -r '.KARAKEEP_OAUTH_CLIENT_SECRET // empty' <<<"$existing_karakeep_secret_json")"

  [[ -n "$existing_nextauth_secret" ]] && karakeep_nextauth_secret="$existing_nextauth_secret"
  [[ -n "$existing_meili_master_key" ]] && karakeep_meili_master_key="$existing_meili_master_key"
  [[ -n "$existing_oauth_client_id" ]] && karakeep_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && karakeep_oauth_client_secret="$existing_oauth_client_secret"
fi

karakeep_secret_file="$(mktemp "${TMPDIR:-/tmp}/karakeep-bootstrap-XXXXXX.json")"
karakeep_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/karakeep-application-XXXXXX.yaml")"
karakeep_rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/karakeep-ingressroute-XXXXXX.yaml")"
trap 'rm -f "$karakeep_secret_file" "$karakeep_rendered_manifest" "$karakeep_rendered_ingressroute"' EXIT

jq -n \
  --arg KARAKEEP_NEXTAUTH_SECRET "$karakeep_nextauth_secret" \
  --arg KARAKEEP_MEILI_MASTER_KEY "$karakeep_meili_master_key" \
  --arg KARAKEEP_OAUTH_CLIENT_ID "$karakeep_oauth_client_id" \
  --arg KARAKEEP_OAUTH_CLIENT_SECRET "$karakeep_oauth_client_secret" \
  '{
    KARAKEEP_NEXTAUTH_SECRET: $KARAKEEP_NEXTAUTH_SECRET,
    KARAKEEP_MEILI_MASTER_KEY: $KARAKEEP_MEILI_MASTER_KEY,
    KARAKEEP_OAUTH_CLIENT_ID: $KARAKEEP_OAUTH_CLIENT_ID,
    KARAKEEP_OAUTH_CLIENT_SECRET: $KARAKEEP_OAUTH_CLIENT_SECRET
  }' >"$karakeep_secret_file"

log "Writing Karakeep bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "karakeep" \
  --json-file "$karakeep_secret_file" \
  --required-keys "KARAKEEP_NEXTAUTH_SECRET,KARAKEEP_MEILI_MASTER_KEY,KARAKEEP_OAUTH_CLIENT_ID,KARAKEEP_OAUTH_CLIENT_SECRET"

log "Provisioning Authentik OIDC client for Karakeep"
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
    --arg name "Karakeep" \
    --arg client_id "$karakeep_oauth_client_id" \
    --arg client_secret "$karakeep_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$KARAKEEP_REDIRECT_URI" \
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
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Karakeep"

application_payload="$(
  jq -n \
    --arg name "Karakeep" \
    --arg slug "karakeep" \
    --arg launch_url "$KARAKEEP_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Karakeep"

log "Applying Karakeep namespace and ingress routes"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/karakeep/namespace.yaml"
render_template \
  "$WORKSPACE_ROOT/gitops/platform-apps/karakeep/ingressroute.yaml" \
  "$karakeep_rendered_ingressroute" \
  "__ZONE_NAME__=$public_zone_name"
kubectl apply -f "$karakeep_rendered_ingressroute"

log "Applying Karakeep Argo CD application"
render_template \
  "$WORKSPACE_ROOT/gitops/apps/karakeep.yaml" \
  "$karakeep_rendered_manifest" \
  "__ZONE_NAME__=$public_zone_name" \
  "__KARAKEEP_NEXTAUTH_SECRET__=$karakeep_nextauth_secret" \
  "__KARAKEEP_MEILI_MASTER_KEY__=$karakeep_meili_master_key" \
  "__KARAKEEP_OAUTH_CLIENT_ID__=$karakeep_oauth_client_id" \
  "__KARAKEEP_OAUTH_CLIENT_SECRET__=$karakeep_oauth_client_secret"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$karakeep_rendered_manifest" \
  --application "karakeep" \
  --destination-namespace "karakeep"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "karakeep" \
    --arg public_url "$KARAKEEP_HOST" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url
    }' >"$STEP_RESULT_FILE"
fi
