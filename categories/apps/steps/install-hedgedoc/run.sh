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
  local zone_name="$3"

  python3 - "$template_file" "$rendered_file" "$zone_name" <<'PY'
from pathlib import Path
import sys

template_file = Path(sys.argv[1])
rendered_file = Path(sys.argv[2])
zone_name = sys.argv[3]

rendered = template_file.read_text(encoding="utf-8").replace("__ZONE_NAME__", zone_name)
rendered_file.write_text(rendered, encoding="utf-8")
PY
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

  existing_pk="$(find_oauth2_provider_pk_by_name "HedgeDoc")"
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

  existing_json="$(find_application_json_by_slug "hedgedoc" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/hedgedoc/" "$application_payload" >/dev/null
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
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
HEDGEDOC_HOST="https://hedgedoc.${public_zone_name}"
HEDGEDOC_REDIRECT_URI="${HEDGEDOC_HOST}/auth/oauth2/callback"

hedgedoc_db_username="hedgedoc"
hedgedoc_db_password="$(openssl rand -hex 24)"
hedgedoc_session_secret="$(openssl rand -hex 32)"
hedgedoc_oauth_client_id="$(openssl rand -hex 16)"
hedgedoc_oauth_client_secret="$(openssl rand -hex 24)"
hedgedoc_database_url="postgresql://${hedgedoc_db_username}:${hedgedoc_db_password}@hedgedoc-db-pooler-rw-session.databases.svc.cluster.local:5432/hedgedoc"

existing_hedgedoc_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_hedgedoc_secret_json="$(openbao_read_global_secret_json hedgedoc 2>/dev/null || true)"
fi

if [[ -n "$existing_hedgedoc_secret_json" ]]; then
  existing_db_username="$(jq -r '.HEDGEDOC_POSTGRESQL__USERNAME // empty' <<<"$existing_hedgedoc_secret_json")"
  existing_db_password="$(jq -r '.HEDGEDOC_POSTGRESQL__PASSWORD // empty' <<<"$existing_hedgedoc_secret_json")"
  existing_database_url="$(jq -r '.HEDGEDOC_DATABASE_URL // empty' <<<"$existing_hedgedoc_secret_json")"
  existing_session_secret="$(jq -r '.HEDGEDOC_SESSION_SECRET // empty' <<<"$existing_hedgedoc_secret_json")"
  existing_oauth_client_id="$(jq -r '.HEDGEDOC_OAUTH2_CLIENT_ID // empty' <<<"$existing_hedgedoc_secret_json")"
  existing_oauth_client_secret="$(jq -r '.HEDGEDOC_OAUTH2_CLIENT_SECRET // empty' <<<"$existing_hedgedoc_secret_json")"

  [[ -n "$existing_db_username" ]] && hedgedoc_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && hedgedoc_db_password="$existing_db_password"
  [[ -n "$existing_database_url" ]] && hedgedoc_database_url="$existing_database_url"
  [[ -n "$existing_session_secret" ]] && hedgedoc_session_secret="$existing_session_secret"
  [[ -n "$existing_oauth_client_id" ]] && hedgedoc_oauth_client_id="$existing_oauth_client_id"
  [[ -n "$existing_oauth_client_secret" ]] && hedgedoc_oauth_client_secret="$existing_oauth_client_secret"
fi

hedgedoc_secret_file="$(mktemp "${TMPDIR:-/tmp}/hedgedoc-bootstrap-XXXXXX.json")"
hedgedoc_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/hedgedoc-application-XXXXXX.yaml")"
hedgedoc_rendered_deployment="$(mktemp "${TMPDIR:-/tmp}/hedgedoc-deployment-XXXXXX.yaml")"
hedgedoc_rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/hedgedoc-ingressroute-XXXXXX.yaml")"
trap 'rm -f "$hedgedoc_secret_file" "$hedgedoc_rendered_manifest" "$hedgedoc_rendered_deployment" "$hedgedoc_rendered_ingressroute"' EXIT

jq -n \
  --arg HEDGEDOC_POSTGRESQL__USERNAME "$hedgedoc_db_username" \
  --arg HEDGEDOC_POSTGRESQL__PASSWORD "$hedgedoc_db_password" \
  --arg HEDGEDOC_DATABASE_URL "$hedgedoc_database_url" \
  --arg HEDGEDOC_SESSION_SECRET "$hedgedoc_session_secret" \
  --arg HEDGEDOC_OAUTH2_CLIENT_ID "$hedgedoc_oauth_client_id" \
  --arg HEDGEDOC_OAUTH2_CLIENT_SECRET "$hedgedoc_oauth_client_secret" \
  '{
    HEDGEDOC_POSTGRESQL__USERNAME: $HEDGEDOC_POSTGRESQL__USERNAME,
    HEDGEDOC_POSTGRESQL__PASSWORD: $HEDGEDOC_POSTGRESQL__PASSWORD,
    HEDGEDOC_DATABASE_URL: $HEDGEDOC_DATABASE_URL,
    HEDGEDOC_SESSION_SECRET: $HEDGEDOC_SESSION_SECRET,
    HEDGEDOC_OAUTH2_CLIENT_ID: $HEDGEDOC_OAUTH2_CLIENT_ID,
    HEDGEDOC_OAUTH2_CLIENT_SECRET: $HEDGEDOC_OAUTH2_CLIENT_SECRET
  }' >"$hedgedoc_secret_file"

log "Writing HedgeDoc bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "hedgedoc" \
  --json-file "$hedgedoc_secret_file" \
  --required-keys "HEDGEDOC_POSTGRESQL__USERNAME,HEDGEDOC_POSTGRESQL__PASSWORD,HEDGEDOC_DATABASE_URL,HEDGEDOC_SESSION_SECRET,HEDGEDOC_OAUTH2_CLIENT_ID,HEDGEDOC_OAUTH2_CLIENT_SECRET"

log "Provisioning Authentik OIDC client for HedgeDoc"
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
    --arg name "HedgeDoc" \
    --arg client_id "$hedgedoc_oauth_client_id" \
    --arg client_secret "$hedgedoc_oauth_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$HEDGEDOC_REDIRECT_URI" \
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
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for HedgeDoc"

application_payload="$(
  jq -n \
    --arg name "HedgeDoc" \
    --arg slug "hedgedoc" \
    --arg launch_url "$HEDGEDOC_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for HedgeDoc"

log "Applying HedgeDoc namespace and database manifests"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/externalsecret.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/cluster.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/pooler-ro.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/pooler-rw.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/pooler-rw-session.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/hedgedoc/scheduled-backup.yaml"

wait_for_resource_ready "databases" "externalsecret/hedgedoc-db-credentials" "Ready" "HedgeDoc database ExternalSecret"
wait_for_resource_ready "databases" "cluster/hedgedoc-db" "Ready" "HedgeDoc CloudNativePG cluster"
wait_for_resource_ready "databases" "deployment/hedgedoc-db-pooler-ro" "Available" "HedgeDoc read-only pooler"
wait_for_resource_ready "databases" "deployment/hedgedoc-db-pooler-rw" "Available" "HedgeDoc read-write pooler"
wait_for_resource_ready "databases" "deployment/hedgedoc-db-pooler-rw-session" "Available" "HedgeDoc session pooler"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "hedgedoc" \
  --host "hedgedoc-db-pooler-rw-session.databases.svc.cluster.local"

log "Applying HedgeDoc app namespace, storage, secrets, and ingress"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/pvc.yaml"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/externalsecret.yaml"
render_template \
  "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/deployment.yaml" \
  "$hedgedoc_rendered_deployment" \
  "$public_zone_name"
kubectl apply -f "$hedgedoc_rendered_deployment"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/service.yaml"
render_template \
  "$WORKSPACE_ROOT/gitops/platform-apps/hedgedoc/ingressroute.yaml" \
  "$hedgedoc_rendered_ingressroute" \
  "$public_zone_name"
kubectl apply -f "$hedgedoc_rendered_ingressroute"

wait_for_resource_ready "hedgedoc" "externalsecret/hedgedoc-bootstrap" "Ready" "HedgeDoc application ExternalSecret"

log "Applying HedgeDoc Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" \
  "$WORKSPACE_ROOT/gitops/apps/hedgedoc.yaml" >"$hedgedoc_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$hedgedoc_rendered_manifest" \
  --application "hedgedoc" \
  --destination-namespace "hedgedoc"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "hedgedoc" \
    --arg public_url "$HEDGEDOC_HOST" \
    --arg database "hedgedoc-db" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database
    }' >"$STEP_RESULT_FILE"
fi
