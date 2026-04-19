#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
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

  existing_pk="$(find_oauth2_provider_pk_by_name "Zulip")"
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

  existing_json="$(find_application_json_by_slug "zulip" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/zulip/" "$application_payload" >/dev/null
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

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
zulip_host="https://zulip.${public_zone_name}"
zulip_redirect_uri="${zulip_host}/complete/oidc/"
zulip_application_slug="zulip"
zulip_issuer_url="${AUTHENTIK_HOST%/}/application/o/${zulip_application_slug}/"
zulip_client_id="$(openssl rand -hex 16)"
zulip_client_secret="$(openssl rand -hex 24)"
zulip_secret_key="$(openssl rand -hex 32)"
secrets_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"
zulip_secret_file="${secrets_dir}/zulip-oidc-${cluster_id}.json"
zulip_manifest_path="$WORKSPACE_ROOT/gitops/apps/zulip.yaml"
zulip_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/zulip-application.XXXXXX.yaml")"
trap 'rm -f "$zulip_rendered_manifest" "$zulip_secret_file"' EXIT

mkdir -p "$secrets_dir"

existing_zulip_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_zulip_secret_json="$(openbao_read_global_secret_json zulip-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_zulip_secret_json" ]]; then
  existing_client_id="$(jq -r '.ZULIP_OIDC_CLIENT_ID // empty' <<<"$existing_zulip_secret_json")"
  existing_client_secret="$(jq -r '.ZULIP_OIDC_CLIENT_SECRET // empty' <<<"$existing_zulip_secret_json")"
  existing_secret_key="$(jq -r '.SECRETS_secret_key // empty' <<<"$existing_zulip_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    zulip_client_id="$existing_client_id"
    zulip_client_secret="$existing_client_secret"
  fi
  if [[ -n "$existing_secret_key" ]]; then
    zulip_secret_key="$existing_secret_key"
  fi
fi

zulip_oidc_idps_json="$(
  jq -n \
    --arg oidc_url "$zulip_issuer_url" \
    --arg display_name "Authentik" \
    --arg client_id "$zulip_client_id" \
    --arg secret "$zulip_client_secret" \
    '{
      authentik: {
        oidc_url: $oidc_url,
        display_name: $display_name,
        client_id: $client_id,
        secret: $secret,
        auto_signup: true
      }
    }'
)"
zulip_oidc_idps_literal="$(
  printf '%s' "$zulip_oidc_idps_json" | python3 -c 'import json, sys; print(repr(json.loads(sys.stdin.read())))'
)"

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

zulip_config_secret_json="$(
  jq -n \
    --arg secret_key "$zulip_secret_key" \
    --arg client_id "$zulip_client_id" \
    --arg client_secret "$zulip_client_secret" \
    --arg oidc_idps "$zulip_oidc_idps_literal" \
    '{
      SECRETS_secret_key: $secret_key,
      ZULIP_OIDC_CLIENT_ID: $client_id,
      ZULIP_OIDC_CLIENT_SECRET: $client_secret,
      SETTING_SOCIAL_AUTH_OIDC_ENABLED_IDPS: $oidc_idps
    }'
)"
printf '%s\n' "$zulip_config_secret_json" >"$zulip_secret_file"
chmod 600 "$zulip_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "zulip-oidc" \
  --json-file "$zulip_secret_file" \
  --required-keys "SECRETS_secret_key,SETTING_SOCIAL_AUTH_OIDC_ENABLED_IDPS"

provider_payload="$(
  jq -n \
    --arg name "Zulip" \
    --arg client_id "$zulip_client_id" \
    --arg client_secret "$zulip_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$zulip_redirect_uri" \
    --argjson property_mappings "$(jq -cn \
      --arg openid "$openid_mapping_id" \
      --arg email "$email_mapping_id" \
      --arg profile "$profile_mapping_id" \
      '[$openid, $email, $profile]')" \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Zulip"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Zulip"

application_payload="$(
  jq -n \
    --arg name "Zulip" \
    --arg slug "$zulip_application_slug" \
    --arg launch_url "$zulip_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Zulip"

sed "s/__ZONE_NAME__/${public_zone_name}/g" "$zulip_manifest_path" >"$zulip_rendered_manifest"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Zulip Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$zulip_rendered_manifest" \
  --application "zulip"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "zulip" \
    --arg manifest_path "$zulip_manifest_path" \
    --arg host "$zulip_host" \
    --arg provider_pk "$provider_pk" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      host: $host,
      provider_pk: $provider_pk
    }' >"$STEP_RESULT_FILE"
fi
