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

wait_for_named_resource_ready() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local label="${4:-$name}"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" get "$kind" "$name" >/dev/null 2>&1; then
      if kubectl -n "$namespace" wait --for="condition=Ready" "$kind" "$name" --timeout=5s >/dev/null 2>&1; then
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

wait_for_deployment_rollout() {
  local namespace="$1"
  local deployment="$2"
  local label="${3:-$deployment}"
  local attempts=120
  local attempt=1

  while true; do
    local status_json desired_replicas updated_replicas ready_replicas available_replicas
    if status_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}"
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

wait_for_deployment_image() {
  local namespace="$1"
  local deployment="$2"
  local label="${3:-$deployment}"
  local attempts=120
  local attempt=1

  while true; do
    local image=""
    image="$(kubectl -n "$namespace" get deployment "$deployment" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [[ -n "$image" ]]; then
      printf '%s\n' "$image"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for ${label} image"
    fi

    log "Waiting for ${label} image to appear (${attempt}/${attempts})"
    sleep 5
    attempt=$((attempt + 1))
  done
}

run_mastodon_db_migrate_job() {
  local mastodon_image="$1"
  local job_name="mastodon-db-migrate-$(date +%s)-$(openssl rand -hex 4)"
  local attempts=120
  local attempt=1

  log "Running Mastodon database migrations"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: mastodon
  labels:
    app.kubernetes.io/name: mastodon-db-migrate
spec:
  backoffLimit: 0
  template:
    metadata:
      name: ${job_name}
      labels:
        app.kubernetes.io/name: mastodon-db-migrate
    spec:
      restartPolicy: Never
      containers:
        - name: mastodon-db-migrate
          image: "${mastodon_image}"
          imagePullPolicy: IfNotPresent
          command:
            - bundle
            - exec
            - rake
            - db:migrate
          envFrom:
            - secretRef:
                name: mastodon-runtime
          env:
            - name: DB_HOST
              value: mastodon-db-rw.databases.svc.cluster.local
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              value: mastodon
            - name: DB_USER
              value: mastodon
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: mastodon-runtime
                  key: password
            - name: REDIS_HOST
              value: mastodon-redis.mastodon.svc.cluster.local
            - name: REDIS_PORT
              value: "6379"
            - name: REDIS_DRIVER
              value: ruby
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mastodon-runtime
                  key: REDIS_PASSWORD
EOF

  while true; do
    local job_status_json complete failed
    job_status_json="$(kubectl -n mastodon get job "$job_name" -o json 2>/dev/null || true)"
    if [[ -n "$job_status_json" ]]; then
      complete="$(jq -r '.status.conditions[]? | select(.type == "Complete" and .status == "True") | .type' <<<"$job_status_json" | head -n1)"
      failed="$(jq -r '.status.conditions[]? | select(.type == "Failed" and .status == "True") | .type' <<<"$job_status_json" | head -n1)"
      if [[ -n "$complete" ]]; then
        log "Mastodon database migrations completed"
        kubectl -n mastodon delete job "$job_name" --ignore-not-found >/dev/null
        return 0
      fi
      if [[ -n "$failed" || "$(jq -r '.status.failed // 0' <<<"$job_status_json")" != "0" ]]; then
        kubectl -n mastodon logs "job/${job_name}" >&2 || true
        fail "Mastodon database migrations failed"
      fi
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      kubectl -n mastodon logs "job/${job_name}" >&2 || true
      fail "Timed out waiting for Mastodon database migrations"
    fi

    log "Waiting for Mastodon database migrations (${attempt}/${attempts})"
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

generate_alphanumeric() {
  local length="${1:-32}"
  node - "$length" <<'NODE'
const crypto = require('node:crypto');

const length = Number(process.argv[2] || 32);
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
const bytes = crypto.randomBytes(length);

let output = '';
for (const byte of bytes) {
  if (output.length >= length) {
    break;
  }
  output += alphabet[byte % alphabet.length];
}

process.stdout.write(output);
NODE
}

generate_vapid_keys() {
  node <<'NODE'
const { generateKeyPairSync } = require('node:crypto');

const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
});

const privateJwk = privateKey.export({ format: 'jwk' });
const publicJwk = publicKey.export({ format: 'jwk' });

const decodeBase64Url = (value) => Buffer.from(value, 'base64url');
const publicKeyRaw = Buffer.concat([
  Buffer.from([0x04]),
  decodeBase64Url(publicJwk.x),
  decodeBase64Url(publicJwk.y),
]).toString('base64url');

process.stdout.write(
  JSON.stringify({
    privateKey: privateJwk.d,
    publicKey: publicKeyRaw,
  })
);
NODE
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

  existing_pk="$(find_oauth2_provider_pk_by_name "Mastodon")"
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

  existing_json="$(find_application_json_by_slug "mastodon" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/mastodon/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

run_mastodon_tootctl() {
  kubectl -n mastodon exec deployment/mastodon-web -- \
    sh -lc 'cd /opt/mastodon && RAILS_ENV=production bin/tootctl "$@"' sh "$@"
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
command -v node >/dev/null 2>&1 || fail "node not found"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
mastodon_host="https://mastodon.${public_zone_name}"
mastodon_admin_username="admin"
mastodon_admin_email="admin@mastodon.${public_zone_name}"
mastodon_oidc_redirect_uri="${mastodon_host}/auth/auth/openid_connect/callback"
mastodon_oidc_issuer="${AUTHENTIK_HOST%/}/application/o/mastodon/"
mastodon_oidc_client_id="$(openssl rand -hex 16)"
mastodon_oidc_client_secret="$(openssl rand -hex 24)"
mastodon_db_username="mastodon"
mastodon_db_password="$(openssl rand -hex 24)"
mastodon_redis_password="$(openssl rand -hex 24)"
mastodon_secret_key_base="$(openssl rand -hex 64)"
mastodon_otp_secret="$(openssl rand -hex 64)"
mastodon_active_record_encryption_primary_key="$(generate_alphanumeric 32)"
mastodon_active_record_encryption_deterministic_key="$(generate_alphanumeric 32)"
mastodon_active_record_encryption_key_derivation_salt="$(generate_alphanumeric 32)"
mastodon_vapid_json="$(generate_vapid_keys)"
mastodon_vapid_private_key="$(jq -r '.privateKey' <<<"$mastodon_vapid_json")"
mastodon_vapid_public_key="$(jq -r '.publicKey' <<<"$mastodon_vapid_json")"
mastodon_admin_password=""

existing_mastodon_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_mastodon_secret_json="$(openbao_read_global_secret_json mastodon 2>/dev/null || true)"
fi

if [[ -n "$existing_mastodon_secret_json" ]]; then
  existing_db_username="$(jq -r '.MASTODON_POSTGRESQL__USERNAME // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_db_password="$(jq -r '.MASTODON_POSTGRESQL__PASSWORD // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_redis_password="$(jq -r '.REDIS_PASSWORD // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_secret_key_base="$(jq -r '.SECRET_KEY_BASE // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_otp_secret="$(jq -r '.OTP_SECRET // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_vapid_private_key="$(jq -r '.VAPID_PRIVATE_KEY // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_vapid_public_key="$(jq -r '.VAPID_PUBLIC_KEY // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_ar_primary_key="$(jq -r '.ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_ar_deterministic_key="$(jq -r '.ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_ar_key_derivation_salt="$(jq -r '.ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_oidc_client_id="$(jq -r '.MASTODON_OIDC_CLIENT_ID // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_oidc_client_secret="$(jq -r '.MASTODON_OIDC_CLIENT_SECRET // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_admin_username="$(jq -r '.MASTODON_ADMIN_USERNAME // empty' <<<"$existing_mastodon_secret_json" || true)"
  existing_admin_password="$(jq -r '.MASTODON_ADMIN_PASSWORD // empty' <<<"$existing_mastodon_secret_json" || true)"

  [[ -n "$existing_db_username" ]] && mastodon_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && mastodon_db_password="$existing_db_password"
  [[ -n "$existing_redis_password" ]] && mastodon_redis_password="$existing_redis_password"
  [[ -n "$existing_secret_key_base" ]] && mastodon_secret_key_base="$existing_secret_key_base"
  [[ -n "$existing_otp_secret" ]] && mastodon_otp_secret="$existing_otp_secret"
  [[ -n "$existing_vapid_private_key" ]] && mastodon_vapid_private_key="$existing_vapid_private_key"
  [[ -n "$existing_vapid_public_key" ]] && mastodon_vapid_public_key="$existing_vapid_public_key"
  [[ -n "$existing_ar_primary_key" ]] && mastodon_active_record_encryption_primary_key="$existing_ar_primary_key"
  [[ -n "$existing_ar_deterministic_key" ]] && mastodon_active_record_encryption_deterministic_key="$existing_ar_deterministic_key"
  [[ -n "$existing_ar_key_derivation_salt" ]] && mastodon_active_record_encryption_key_derivation_salt="$existing_ar_key_derivation_salt"
  [[ -n "$existing_oidc_client_id" ]] && mastodon_oidc_client_id="$existing_oidc_client_id"
  [[ -n "$existing_oidc_client_secret" ]] && mastodon_oidc_client_secret="$existing_oidc_client_secret"
  [[ -n "$existing_admin_username" ]] && mastodon_admin_username="$existing_admin_username"
  [[ -n "$existing_admin_password" ]] && mastodon_admin_password="$existing_admin_password"
fi

mastodon_secret_file="$(mktemp "${TMPDIR:-/tmp}/mastodon-bootstrap-XXXXXX")"
mastodon_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/mastodon-application-XXXXXX")"
trap 'rm -f "$mastodon_secret_file" "$mastodon_rendered_manifest"' EXIT

jq -n \
  --arg MASTODON_POSTGRESQL__USERNAME "$mastodon_db_username" \
  --arg MASTODON_POSTGRESQL__PASSWORD "$mastodon_db_password" \
  --arg REDIS_PASSWORD "$mastodon_redis_password" \
  --arg SECRET_KEY_BASE "$mastodon_secret_key_base" \
  --arg OTP_SECRET "$mastodon_otp_secret" \
  --arg VAPID_PRIVATE_KEY "$mastodon_vapid_private_key" \
  --arg VAPID_PUBLIC_KEY "$mastodon_vapid_public_key" \
  --arg ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY "$mastodon_active_record_encryption_primary_key" \
  --arg ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY "$mastodon_active_record_encryption_deterministic_key" \
  --arg ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT "$mastodon_active_record_encryption_key_derivation_salt" \
  --arg MASTODON_OIDC_CLIENT_ID "$mastodon_oidc_client_id" \
  --arg MASTODON_OIDC_CLIENT_SECRET "$mastodon_oidc_client_secret" \
  --arg MASTODON_ADMIN_USERNAME "$mastodon_admin_username" \
  '{
    MASTODON_POSTGRESQL__USERNAME: $MASTODON_POSTGRESQL__USERNAME,
    MASTODON_POSTGRESQL__PASSWORD: $MASTODON_POSTGRESQL__PASSWORD,
    REDIS_PASSWORD: $REDIS_PASSWORD,
    SECRET_KEY_BASE: $SECRET_KEY_BASE,
    OTP_SECRET: $OTP_SECRET,
    VAPID_PRIVATE_KEY: $VAPID_PRIVATE_KEY,
    VAPID_PUBLIC_KEY: $VAPID_PUBLIC_KEY,
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: $ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: $ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: $ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,
    MASTODON_OIDC_CLIENT_ID: $MASTODON_OIDC_CLIENT_ID,
    MASTODON_OIDC_CLIENT_SECRET: $MASTODON_OIDC_CLIENT_SECRET,
    MASTODON_ADMIN_USERNAME: $MASTODON_ADMIN_USERNAME
  }' >"$mastodon_secret_file"

log "Writing Mastodon bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "mastodon" \
  --json-file "$mastodon_secret_file" \
  --required-keys "MASTODON_POSTGRESQL__USERNAME,MASTODON_POSTGRESQL__PASSWORD,REDIS_PASSWORD,SECRET_KEY_BASE,OTP_SECRET,VAPID_PRIVATE_KEY,VAPID_PUBLIC_KEY,ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,MASTODON_OIDC_CLIENT_ID,MASTODON_OIDC_CLIENT_SECRET,MASTODON_ADMIN_USERNAME"

log "Applying Mastodon namespaces and ExternalSecrets"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/mastodon/namespace.yaml" >/dev/null
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/shared/namespace.yaml" >/dev/null
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/mastodon/externalsecret-runtime.yaml" >/dev/null
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform-apps/mastodon/externalsecret-s3.yaml" >/dev/null
kubectl apply -f "$WORKSPACE_ROOT/gitops/databases/mastodon/externalsecret.yaml" >/dev/null

openbao_wait_for_external_secret_ready "mastodon" "mastodon-runtime"
openbao_wait_for_secret "mastodon-runtime" "mastodon"
openbao_wait_for_external_secret_ready "mastodon" "mastodon-s3"
openbao_wait_for_secret "mastodon-s3" "mastodon"
openbao_wait_for_external_secret_ready "databases" "mastodon-db-credentials"
openbao_wait_for_secret "mastodon-db-credentials" "databases"

log "Provisioning Authentik OIDC client for Mastodon"
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

property_mappings_json="$(jq -cn --arg openid "$openid_mapping_id" --arg email "$email_mapping_id" --arg profile "$profile_mapping_id" '[$openid, $email, $profile]')"

provider_payload="$(
  jq -n \
    --arg name "Mastodon" \
    --arg client_id "$mastodon_oidc_client_id" \
    --arg client_secret "$mastodon_oidc_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$mastodon_oidc_redirect_uri" \
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
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider"
    }'
)"

provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Mastodon"

application_payload="$(
  jq -n \
    --arg name "Mastodon" \
    --arg slug "mastodon" \
    --arg launch_url "$mastodon_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Mastodon"

log "Applying Mastodon Argo CD application"
render_template \
  "$WORKSPACE_ROOT/gitops/apps/mastodon.yaml" \
  "$mastodon_rendered_manifest" \
  "__ZONE_NAME__=${public_zone_name}" \
  "__MASTODON_OIDC_CLIENT_ID__=${mastodon_oidc_client_id}" \
  "__MASTODON_OIDC_CLIENT_SECRET__=${mastodon_oidc_client_secret}"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$mastodon_rendered_manifest" \
  --application "mastodon" \
  --destination-namespace "mastodon"

wait_for_named_resource_ready "mastodon" "externalsecret" "mastodon-runtime" "Mastodon runtime ExternalSecret"
wait_for_named_resource_ready "mastodon" "externalsecret" "mastodon-s3" "Mastodon S3 ExternalSecret"
wait_for_named_resource_ready "databases" "externalsecret" "mastodon-db-credentials" "Mastodon database ExternalSecret"
wait_for_named_resource_ready "databases" "cluster" "mastodon-db" "Mastodon CloudNativePG cluster"
wait_for_deployment_rollout "mastodon" "mastodon-redis" "Mastodon Redis"
mastodon_web_image="$(wait_for_deployment_image "mastodon" "mastodon-web" "Mastodon web")"
run_mastodon_db_migrate_job "$mastodon_web_image"
wait_for_deployment_rollout "mastodon" "mastodon-web" "Mastodon web"
wait_for_deployment_rollout "mastodon" "mastodon-streaming" "Mastodon streaming"
wait_for_deployment_rollout "mastodon" "mastodon-sidekiq-all-queues" "Mastodon Sidekiq"

mastodon_admin_password_changed=false
if [[ -n "$mastodon_admin_password" ]]; then
  log "Ensuring Mastodon admin account exists and remains approved"
  set +e
  mastodon_admin_output="$(run_mastodon_tootctl accounts modify "$mastodon_admin_username" --approve --confirm --role Owner 2>&1)"
  mastodon_admin_status=$?
  set -e

  if [[ "$mastodon_admin_status" -eq 0 ]]; then
    log "Mastodon admin account already exists"
  else
    log "Creating Mastodon admin account"
    mastodon_admin_output="$(run_mastodon_tootctl accounts create "$mastodon_admin_username" --email "$mastodon_admin_email" --confirmed --role Owner --approve 2>&1)" \
      || fail "Failed to create Mastodon admin account: ${mastodon_admin_output}"
    mastodon_admin_password_changed=true
  fi
else
  log "Creating or resetting the Mastodon admin account password"
  set +e
  mastodon_admin_output="$(run_mastodon_tootctl accounts modify "$mastodon_admin_username" --approve --confirm --role Owner --reset-password 2>&1)"
  mastodon_admin_status=$?
  set -e

  if [[ "$mastodon_admin_status" -eq 0 ]]; then
    mastodon_admin_password_changed=true
  else
    log "Creating Mastodon admin account"
    mastodon_admin_output="$(run_mastodon_tootctl accounts create "$mastodon_admin_username" --email "$mastodon_admin_email" --confirmed --role Owner --approve 2>&1)" \
      || fail "Failed to create Mastodon admin account: ${mastodon_admin_output}"
    mastodon_admin_password_changed=true
  fi
fi

if [[ "$mastodon_admin_password_changed" == true ]]; then
  mastodon_admin_password="$(printf '%s\n' "$mastodon_admin_output" | sed -n 's/^New password: //p' | tail -n1)"
  [[ -n "$mastodon_admin_password" ]] || fail "Could not read the Mastodon admin password from tootctl output"
fi

jq -n \
  --arg MASTODON_POSTGRESQL__USERNAME "$mastodon_db_username" \
  --arg MASTODON_POSTGRESQL__PASSWORD "$mastodon_db_password" \
  --arg REDIS_PASSWORD "$mastodon_redis_password" \
  --arg SECRET_KEY_BASE "$mastodon_secret_key_base" \
  --arg OTP_SECRET "$mastodon_otp_secret" \
  --arg VAPID_PRIVATE_KEY "$mastodon_vapid_private_key" \
  --arg VAPID_PUBLIC_KEY "$mastodon_vapid_public_key" \
  --arg ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY "$mastodon_active_record_encryption_primary_key" \
  --arg ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY "$mastodon_active_record_encryption_deterministic_key" \
  --arg ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT "$mastodon_active_record_encryption_key_derivation_salt" \
  --arg MASTODON_OIDC_CLIENT_ID "$mastodon_oidc_client_id" \
  --arg MASTODON_OIDC_CLIENT_SECRET "$mastodon_oidc_client_secret" \
  --arg MASTODON_ADMIN_USERNAME "$mastodon_admin_username" \
  --arg MASTODON_ADMIN_PASSWORD "$mastodon_admin_password" \
  '{
    MASTODON_POSTGRESQL__USERNAME: $MASTODON_POSTGRESQL__USERNAME,
    MASTODON_POSTGRESQL__PASSWORD: $MASTODON_POSTGRESQL__PASSWORD,
    REDIS_PASSWORD: $REDIS_PASSWORD,
    SECRET_KEY_BASE: $SECRET_KEY_BASE,
    OTP_SECRET: $OTP_SECRET,
    VAPID_PRIVATE_KEY: $VAPID_PRIVATE_KEY,
    VAPID_PUBLIC_KEY: $VAPID_PUBLIC_KEY,
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: $ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: $ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: $ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,
    MASTODON_OIDC_CLIENT_ID: $MASTODON_OIDC_CLIENT_ID,
    MASTODON_OIDC_CLIENT_SECRET: $MASTODON_OIDC_CLIENT_SECRET,
    MASTODON_ADMIN_USERNAME: $MASTODON_ADMIN_USERNAME,
    MASTODON_ADMIN_PASSWORD: $MASTODON_ADMIN_PASSWORD
  }' >"$mastodon_secret_file"

log "Updating Mastodon bootstrap secret in OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "mastodon" \
  --json-file "$mastodon_secret_file" \
  --required-keys "MASTODON_POSTGRESQL__USERNAME,MASTODON_POSTGRESQL__PASSWORD,REDIS_PASSWORD,SECRET_KEY_BASE,OTP_SECRET,VAPID_PRIVATE_KEY,VAPID_PUBLIC_KEY,ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,MASTODON_OIDC_CLIENT_ID,MASTODON_OIDC_CLIENT_SECRET,MASTODON_ADMIN_USERNAME,MASTODON_ADMIN_PASSWORD"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "mastodon" \
  --host "mastodon-db-pooler-rw-session.databases.svc.cluster.local"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "mastodon" \
    --arg public_url "$mastodon_host" \
    --arg database "mastodon-db" \
    --arg admin_username "$mastodon_admin_username" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      public_url: $public_url,
      database: $database,
      admin_username: $admin_username
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "mastodon" \
  --service-domain "mastodon.${public_zone_name}" \
  --service-path /
