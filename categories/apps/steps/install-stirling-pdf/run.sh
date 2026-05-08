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
  local status_json=""
  local message=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get "$resource" -o json 2>/dev/null)"; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$resource" --timeout=5s >/dev/null 2>&1; then
        log "${label} is ready"
        return 0
      fi

      message="$(
        jq -r '
          [
            .status.conditions[]?
            | select((.type // "") == $condition)
            | (.reason // empty), (.message // empty)
          ] | map(select(. != "")) | join(": ")
        ' --arg condition "$condition" <<<"$status_json"
      )"
      log "Waiting for ${label} (${attempt}/${attempts})${message:+: ${message}}"
    else
      log "Waiting for ${label} to appear (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become ready after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_pvc_bound() {
  local namespace="$1"
  local pvc="$2"
  local label="$3"
  local attempts=120
  local attempt=1
  local phase=""

  while true; do
    phase="$(kubectl -n "$namespace" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Bound" ]]; then
      log "${label} is bound"
      return 0
    fi

    log "Waiting for ${label} (${attempt}/${attempts}): phase=${phase:-Missing}"
    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become Bound after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_deployment_rollout() {
  local namespace="$1"
  local deployment="$2"
  local label="${3:-$deployment}"
  local attempts=120
  local attempt=1
  local status_json=""
  local desired_replicas=""
  local updated_replicas=""
  local ready_replicas=""
  local available_replicas=""
  local progressing_status=""
  local progressing_reason=""
  local available_status=""
  local available_reason=""
  local message=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"
      progressing_status="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .status // "Unknown"' <<<"$status_json")"
      progressing_reason="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .reason // empty' <<<"$status_json")"
      available_status="$(jq -r '.status.conditions[]? | select(.type == "Available") | .status // "Unknown"' <<<"$status_json")"
      available_reason="$(jq -r '.status.conditions[]? | select(.type == "Available") | .reason // empty' <<<"$status_json")"
      message="$(jq -r '.status.conditions[]? | select(.type == "Progressing" or .type == "Available") | .message // empty' <<<"$status_json" | awk 'NF { if (out) out = out " | "; out = out $0 } END { print out }')"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}, progressing=${progressing_status}${progressing_reason:+/${progressing_reason}}, available=${available_status}${available_reason:+/${available_reason}}${message:+, message=${message}}"
    else
      log "Waiting for ${label} deployment to appear (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for ${label}"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
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

  existing_pk="$(find_oauth2_provider_pk_by_name "Stirling PDF")"
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

  existing_json="$(find_application_json_by_slug "stirling-pdf" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/stirling-pdf/" "$application_payload" >/dev/null
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

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

stirling_api_key="$(openssl rand -hex 32)"
stirling_oauth_client_id="$(openssl rand -hex 16)"
stirling_oauth_client_secret="$(openssl rand -hex 24)"

existing_stirling_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_stirling_secret_json="$(openbao_read_global_secret_json stirling-pdf 2>/dev/null || true)"
fi

if [[ -n "$existing_stirling_secret_json" ]]; then
  existing_api_key="$(jq -r '.STIRLING_PDF_API_KEY // empty' <<<"$existing_stirling_secret_json" || true)"
  [[ -n "$existing_api_key" ]] && stirling_api_key="$existing_api_key"
  existing_oauth_client_id="$(jq -r '.STIRLING_PDF_OAUTH2_CLIENT_ID // empty' <<<"$existing_stirling_secret_json" || true)"
  [[ -n "$existing_oauth_client_id" ]] && stirling_oauth_client_id="$existing_oauth_client_id"
  existing_oauth_client_secret="$(jq -r '.STIRLING_PDF_OAUTH2_CLIENT_SECRET // empty' <<<"$existing_stirling_secret_json" || true)"
  [[ -n "$existing_oauth_client_secret" ]] && stirling_oauth_client_secret="$existing_oauth_client_secret"
fi

stirling_secret_file="$(mktemp "${TMPDIR:-/tmp}/stirling-pdf-bootstrap.XXXXXX.json")"
stirling_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/stirling-pdf-application.XXXXXX.yaml")"
trap 'rm -f "$stirling_secret_file" "$stirling_rendered_manifest"' EXIT

jq -n \
  --arg STIRLING_PDF_API_KEY "$stirling_api_key" \
  --arg STIRLING_PDF_OAUTH2_CLIENT_ID "$stirling_oauth_client_id" \
  --arg STIRLING_PDF_OAUTH2_CLIENT_SECRET "$stirling_oauth_client_secret" \
  '{
    STIRLING_PDF_API_KEY: $STIRLING_PDF_API_KEY,
    STIRLING_PDF_OAUTH2_CLIENT_ID: $STIRLING_PDF_OAUTH2_CLIENT_ID,
    STIRLING_PDF_OAUTH2_CLIENT_SECRET: $STIRLING_PDF_OAUTH2_CLIENT_SECRET
  }' >"$stirling_secret_file"

log "Writing Stirling PDF bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "stirling-pdf" \
  --json-file "$stirling_secret_file" \
  --required-keys "STIRLING_PDF_API_KEY,STIRLING_PDF_OAUTH2_CLIENT_ID,STIRLING_PDF_OAUTH2_CLIENT_SECRET"

log "Provisioning Authentik OIDC client for Stirling PDF"
STIRLING_HOST="https://stirling-pdf.${public_zone_name}"
STIRLING_REDIRECT_URI="${STIRLING_HOST}/login/oauth2/code/authentik"

authentik_ensure_token
authentik_setup_forward

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
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID"

property_mappings_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Stirling PDF" \
    --arg client_id "$stirling_oauth_client_id" \
    --arg client_secret "$stirling_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$STIRLING_REDIRECT_URI" \
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
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Stirling PDF"

application_payload="$(
  jq -n \
    --arg name "Stirling PDF" \
    --arg slug "stirling-pdf" \
    --arg launch_url "$STIRLING_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Stirling PDF"

manifest_path="$WORKSPACE_ROOT/gitops/apps/stirling-pdf.yaml"
log "Applying Stirling PDF Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$stirling_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$stirling_rendered_manifest" \
  --application "stirling-pdf" \
  --no-wait

wait_for_resource_ready "stirling-pdf" "externalsecret/stirling-pdf-config" "Ready" "Stirling PDF ExternalSecret"
wait_for_pvc_bound "stirling-pdf" "stirling-pdf-data" "Stirling PDF data PVC"
wait_for_deployment_rollout "stirling-pdf" "stirling-pdf" "Stirling PDF application"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "stirling-pdf" \
    --arg manifest_path "$manifest_path" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
