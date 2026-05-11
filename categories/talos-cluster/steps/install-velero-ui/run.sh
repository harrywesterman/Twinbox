#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
VELERO_UI_SECRET_FILE="${BOOTSTRAP_ROOT}/secrets/global/velero-ui.json"
VELERO_UI_APP_MANIFEST_PATH="${WORKSPACE_ROOT}/gitops/apps/velero-ui.yaml"
VELERO_UI_PLATFORM_DIR="${WORKSPACE_ROOT}/gitops/platform-apps/velero-ui"
VELERO_UI_NAMESPACE="${VELERO_UI_NAMESPACE:-velero-ui}"
VELERO_UI_APPLICATION_SLUG="${VELERO_UI_APPLICATION_SLUG:-velero-ui}"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

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

wait_for_secret() {
  local namespace="$1"
  local secret_name="$2"
  local timeout_seconds="${3:-600}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Timed out waiting for secret ${namespace}/${secret_name}"
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

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk response_file http_status response_json

  existing_pk="$(find_oauth2_provider_pk_by_name "Velero UI")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

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
      printf '%s\n' "$existing_pk"
      return 0
    fi
  fi

  existing_pk="$(find_oauth2_provider_pk_by_name "Velero UI")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose a provider ID for Velero UI"

  authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
  printf '%s\n' "$existing_pk"
}

create_or_update_application() {
  local application_payload="$1"
  local existing_json existing_pk response_file http_status response_json created_pk

  existing_json="$(find_application_json_by_slug "$VELERO_UI_APPLICATION_SLUG" || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${VELERO_UI_APPLICATION_SLUG}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

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

  if [[ "$http_status" =~ ^2 ]]; then
    response_json="$(cat "$response_file" 2>/dev/null || true)"
    created_pk="$(extract_authentik_identifier "$response_json")"
    if [[ -n "$created_pk" ]]; then
      rm -f "$response_file"
      printf '%s\n' "$created_pk"
      return 0
    fi
  fi

  existing_json="$(find_application_json_by_slug "$VELERO_UI_APPLICATION_SLUG" || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  rm -f "$response_file"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose an application ID for Velero UI"

  authentik_api_write PATCH "/core/applications/${VELERO_UI_APPLICATION_SLUG}/" "$application_payload" >/dev/null
  printf '%s\n' "$existing_pk"
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

resolve_scope_mapping_id() {
  local scope_name="$1"
  authentik_resolve_scope_mapping_id "$scope_name"
}

extract_authentik_identifier() {
  local payload="${1:-}"

  [[ -n "$payload" ]] || return 0
  jq -er '.pk // .uuid // .id // empty' <<<"$payload" 2>/dev/null || true
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

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
velero_ui_host="https://velero-ui.${public_zone_name}"
velero_ui_redirect_uri="${velero_ui_host}/login"
velero_ui_issuer_url="${AUTHENTIK_HOST%/}/application/o/${VELERO_UI_APPLICATION_SLUG}/"
velero_ui_secret_passphrase="$(openssl rand -hex 32)"
velero_ui_client_id="$(openssl rand -hex 16)"
velero_ui_client_secret="$(openssl rand -hex 24)"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"

[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

existing_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_secret_json="$(openbao_read_global_secret_json velero-ui 2>/dev/null || true)"
fi

if [[ -n "$existing_secret_json" ]]; then
  existing_secret_passphrase="$(jq -r '.pass_phrase // .AUTH_SECRET_PASSPHRASE // empty' <<<"$existing_secret_json")"
  existing_client_id="$(jq -r '.OAUTH_CLIENT_ID // empty' <<<"$existing_secret_json")"
  existing_client_secret="$(jq -r '.OAUTH_CLIENT_SECRET // empty' <<<"$existing_secret_json")"
  existing_authorization_url="$(jq -r '.OAUTH_AUTHORIZATION_URL // empty' <<<"$existing_secret_json")"
  existing_token_url="$(jq -r '.OAUTH_TOKEN_URL // empty' <<<"$existing_secret_json")"
  existing_user_info_url="$(jq -r '.OAUTH_USER_INFO_URL // empty' <<<"$existing_secret_json")"
  existing_redirect_uri="$(jq -r '.OAUTH_REDIRECT_URI // empty' <<<"$existing_secret_json")"

  if [[ -n "$existing_secret_passphrase" ]]; then
    velero_ui_secret_passphrase="$existing_secret_passphrase"
  fi
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    velero_ui_client_id="$existing_client_id"
    velero_ui_client_secret="$existing_client_secret"
  fi
  if [[ -n "$existing_authorization_url" ]]; then
    velero_ui_authorization_url="$existing_authorization_url"
  fi
  if [[ -n "$existing_token_url" ]]; then
    velero_ui_token_url="$existing_token_url"
  fi
  if [[ -n "$existing_user_info_url" ]]; then
    velero_ui_user_info_url="$existing_user_info_url"
  fi
  if [[ -n "$existing_redirect_uri" ]]; then
    velero_ui_redirect_uri="$existing_redirect_uri"
  fi
fi

velero_ui_authorization_url="${velero_ui_authorization_url:-${AUTHENTIK_HOST%/}/application/o/authorize/}"
velero_ui_token_url="${velero_ui_token_url:-${AUTHENTIK_HOST%/}/application/o/token/}"
velero_ui_user_info_url="${velero_ui_user_info_url:-${AUTHENTIK_HOST%/}/application/o/userinfo/}"

mkdir -p "$(dirname "$VELERO_UI_SECRET_FILE")"
jq -n \
  --arg pass_phrase "$velero_ui_secret_passphrase" \
  --arg auth_secret_passphrase "$velero_ui_secret_passphrase" \
  --arg basic_auth_enabled "false" \
  --arg oauth_auth_enabled "true" \
  --arg oauth_client_id "$velero_ui_client_id" \
  --arg oauth_client_secret "$velero_ui_client_secret" \
  --arg oauth_authorization_url "$velero_ui_authorization_url" \
  --arg oauth_token_url "$velero_ui_token_url" \
  --arg oauth_user_info_url "$velero_ui_user_info_url" \
  --arg oauth_redirect_uri "$velero_ui_redirect_uri" \
  '{
    pass_phrase: $pass_phrase,
    AUTH_SECRET_PASSPHRASE: $auth_secret_passphrase,
    BASIC_AUTH_ENABLED: $basic_auth_enabled,
    OAUTH_AUTH_ENABLED: $oauth_auth_enabled,
    OAUTH_CLIENT_ID: $oauth_client_id,
    OAUTH_CLIENT_SECRET: $oauth_client_secret,
    OAUTH_AUTHORIZATION_URL: $oauth_authorization_url,
    OAUTH_TOKEN_URL: $oauth_token_url,
    OAUTH_USER_INFO_URL: $oauth_user_info_url,
    OAUTH_REDIRECT_URI: $oauth_redirect_uri
  }' >"$VELERO_UI_SECRET_FILE"
chmod 600 "$VELERO_UI_SECRET_FILE"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "velero-ui" \
  --json-file "$VELERO_UI_SECRET_FILE" \
  --required-keys "pass_phrase,AUTH_SECRET_PASSPHRASE,BASIC_AUTH_ENABLED,OAUTH_AUTH_ENABLED,OAUTH_CLIENT_ID,OAUTH_CLIENT_SECRET,OAUTH_AUTHORIZATION_URL,OAUTH_TOKEN_URL,OAUTH_USER_INFO_URL,OAUTH_REDIRECT_URI"

authentik_provider_payload="$(
  jq -n \
    --arg name "Velero UI" \
    --arg client_id "$velero_ui_client_id" \
    --arg client_secret "$velero_ui_client_secret" \
    --arg authorization_flow "$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")" \
    --arg invalidation_flow "$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")" \
    --arg signing_key "$(authentik_resolve_signing_key_id)" \
    --arg redirect_uri "$velero_ui_redirect_uri" \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Velero UI"
provider_pk="$(create_or_update_provider "$authentik_provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Velero UI"

application_payload="$(
  jq -n \
    --arg name "Velero UI" \
    --arg slug "$VELERO_UI_APPLICATION_SLUG" \
    --arg launch_url "$velero_ui_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Velero UI"

application_json="$(find_application_json_by_slug "$VELERO_UI_APPLICATION_SLUG")"
application_uuid="$(extract_authentik_identifier "$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Velero UI"
ensure_group_binding "$application_uuid" "$admins_group_id"

kubectl create namespace "$VELERO_UI_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$VELERO_UI_PLATFORM_DIR/namespace.yaml"
kubectl apply -f "$VELERO_UI_PLATFORM_DIR/externalsecret.yaml"
kubectl -n "$VELERO_UI_NAMESPACE" wait --for=condition=Ready externalsecret/velero-ui-bootstrap --timeout=10m
wait_for_secret "$VELERO_UI_NAMESPACE" "velero-ui-bootstrap"

velero_ui_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/velero-ui-application-XXXXXX.yaml")"
trap 'rm -f "$velero_ui_rendered_manifest"' EXIT
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$VELERO_UI_APP_MANIFEST_PATH" >"$velero_ui_rendered_manifest"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Velero UI Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$velero_ui_rendered_manifest" \
  --application "velero-ui"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "velero-ui" \
    --arg manifest_path "$VELERO_UI_APP_MANIFEST_PATH" \
    --arg namespace "$VELERO_UI_NAMESPACE" \
    --arg host "$velero_ui_host" \
    --arg provider_pk "$provider_pk" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      namespace: $namespace,
      host: $host,
      provider_pk: $provider_pk
    }' >"$STEP_RESULT_FILE"
fi
