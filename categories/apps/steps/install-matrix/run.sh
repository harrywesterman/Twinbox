#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

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

wait_for_statefulset_ready() {
  local namespace="$1"
  local statefulset="$2"
  local label="${3:-$statefulset}"
  local attempts=120
  local attempt=1

  while true; do
    local status_json replicas ready_replicas
    if status_json="$(kubectl -n "$namespace" get statefulset "$statefulset" -o json 2>/dev/null)"; then
      replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      if [[ "$replicas" == "$ready_replicas" && "$replicas" != "0" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): ready=${ready_replicas}, desired=${replicas}"
    else
      log "Waiting for ${label} statefulset to appear (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for ${label}"
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

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

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

  existing_pk="$(find_oauth2_provider_pk_by_name "Matrix")"
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

  existing_json="$(find_application_json_by_slug "matrix" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/matrix/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_scope_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_scope_id" ]] || fail "Could not determine cluster scope ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

create_users_state_file="$MANAGER_DATA_DIR/step-state/clusters/${cluster_scope_id}/create-users-and-groups.json"
matrix_default_owner_email="admin@${public_zone_name}"
matrix_default_owner_name="Twinbox Admin"
if [[ -f "$create_users_state_file" ]]; then
  step_owner_email="$(jq -r '.outputs.email // empty' "$create_users_state_file")"
  step_owner_name="$(jq -r '.outputs.full_name // empty' "$create_users_state_file")"
  if [[ -n "$step_owner_email" ]]; then
    matrix_default_owner_email="$step_owner_email"
  fi
  if [[ -n "$step_owner_name" ]]; then
    matrix_default_owner_name="$step_owner_name"
  fi
fi

# The owner account is the MAS admin (can request Synapse/MAS admin scopes in
# Element Admin). Authentik's preferred_username (and thus the MAS localpart)
# equals the email local-part of the owner account.
matrix_admin_username="${matrix_default_owner_email%@*}"
[[ -n "$matrix_admin_username" ]] || fail "Could not determine Matrix admin username"
matrix_policy_config="$(
  cat <<EOF
policy:
  data:
    admin_users:
      - "${matrix_admin_username}"
EOF
)"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
matrix_host="https://matrix.${public_zone_name}"
mas_host="https://account.${public_zone_name}"
mas_application_slug="matrix"
mas_issuer_url="${AUTHENTIK_HOST%/}/application/o/${mas_application_slug}/"
mas_client_id="$(openssl rand -hex 16)"
mas_client_secret="$(openssl rand -hex 24)"
synapse_shared_secret="$(openssl rand -hex 32)"
mas_encryption_secret="$(openssl rand -hex 32)"
mas_signing_key="$(openssl genpkey -algorithm RSA -outform PEM -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
mas_oidc_provider_ulid="$(python3 -c "import uuid; import time; ts = int(time.time() * 1000); ulid = format(ts, '012X') + uuid.uuid4().hex[:14].upper(); print(ulid)")"
mas_redirect_uri="${mas_host}/upstream/callback/${mas_oidc_provider_ulid}"
matrix_synapse_db_username="matrix_synapse"
matrix_synapse_db_password="$(openssl rand -hex 24)"
matrix_mas_db_username="matrix_mas"
matrix_mas_db_password="$(openssl rand -hex 24)"
secrets_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"
matrix_oidc_secret_file="${secrets_dir}/matrix-oidc-${cluster_id}.json"
matrix_db_secret_file="${secrets_dir}/matrix-db-${cluster_id}.json"
matrix_runtime_secret_file="${secrets_dir}/matrix-runtime-${cluster_id}.json"
matrix_manifest_path="$WORKSPACE_ROOT/gitops/apps/matrix.yaml"
trap 'rm -f "$matrix_oidc_secret_file" "$matrix_db_secret_file" "$matrix_runtime_secret_file"' EXIT

mkdir -p "$secrets_dir"

# Check for existing secrets in OpenBao (idempotent re-runs)
existing_matrix_oidc_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_matrix_oidc_secret_json="$(openbao_read_global_secret_json matrix-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_matrix_oidc_secret_json" ]]; then
  existing_client_id="$(jq -r '.MAS_OIDC_CLIENT_ID // empty' <<<"$existing_matrix_oidc_secret_json")"
  existing_client_secret="$(jq -r '.MAS_OIDC_CLIENT_SECRET // empty' <<<"$existing_matrix_oidc_secret_json")"
  existing_provider_ulid="$(jq -r '.MAS_OIDC_PROVIDER_ULID // empty' <<<"$existing_matrix_oidc_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    mas_client_id="$existing_client_id"
    mas_client_secret="$existing_client_secret"
  fi
  if [[ -n "$existing_provider_ulid" ]]; then
    mas_oidc_provider_ulid="$existing_provider_ulid"
  fi
fi

existing_matrix_db_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_matrix_db_secret_json="$(openbao_read_global_secret_json matrix-db 2>/dev/null || true)"
fi

if [[ -n "$existing_matrix_db_secret_json" ]]; then
  existing_synapse_db_password="$(jq -r '.MATRIX_SYNAPSE_POSTGRESQL__PASSWORD // empty' <<<"$existing_matrix_db_secret_json")"
  existing_mas_db_password="$(jq -r '.MATRIX_MAS_POSTGRESQL__PASSWORD // empty' <<<"$existing_matrix_db_secret_json")"
  if [[ -n "$existing_synapse_db_password" ]]; then
    matrix_synapse_db_password="$existing_synapse_db_password"
  fi
  if [[ -n "$existing_mas_db_password" ]]; then
    matrix_mas_db_password="$existing_mas_db_password"
  fi
fi

existing_matrix_runtime_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_matrix_runtime_secret_json="$(openbao_read_global_secret_json matrix-runtime 2>/dev/null || true)"
fi

if [[ -n "$existing_matrix_runtime_secret_json" ]]; then
  existing_shared_secret="$(jq -r '.MATRIX_SYNAPSE_SHARED_SECRET // empty' <<<"$existing_matrix_runtime_secret_json")"
  existing_encryption_secret="$(jq -r '.MATRIX_MAS_ENCRYPTION_SECRET // empty' <<<"$existing_matrix_runtime_secret_json")"
  if [[ -n "$existing_shared_secret" ]]; then
    synapse_shared_secret="$existing_shared_secret"
  fi
  if [[ -n "$existing_encryption_secret" ]]; then
    mas_encryption_secret="$existing_encryption_secret"
  fi
fi

matrix_oidc_upstream_config="$(
  cat <<EOF
upstream_oauth2:
  providers:
    - id: "${mas_oidc_provider_ulid}"
      issuer: "${mas_issuer_url}"
      human_name: Authentik
      client_id: "${mas_client_id}"
      client_secret: "${mas_client_secret}"
      token_endpoint_auth_method: client_secret_post
      scope: "openid email profile"
      claims_imports:
        localpart:
          action: force
          template: "{{ user.preferred_username }}"
        displayname:
          action: suggest
          template: "{{ user.name }}"
        email:
          action: suggest
          template: "{{ user.email }}"
EOF
)"

# Write OIDC secret
matrix_oidc_secret_json="$(
  jq -n \
    --arg client_id "$mas_client_id" \
    --arg client_secret "$mas_client_secret" \
    --arg provider_ulid "$mas_oidc_provider_ulid" \
    --arg upstream_config "$matrix_oidc_upstream_config" \
    --arg oidc_idps "$(jq -n \
      --arg oidc_url "$mas_issuer_url" \
      --arg display_name "Authentik" \
      --arg client_id "$mas_client_id" \
      --arg secret "$mas_client_secret" \
      '{
        authentik: {
          oidc_url: $oidc_url,
          display_name: $display_name,
          client_id: $client_id,
          secret: $secret,
          auto_signup: true
        }
      }')" \
    --arg policy_config "$matrix_policy_config" \
    '{
      MAS_OIDC_CLIENT_ID: $client_id,
      MAS_OIDC_CLIENT_SECRET: $client_secret,
      MAS_OIDC_PROVIDER_ULID: $provider_ulid,
      MATRIX_OIDC_ENABLED_IDPS: $oidc_idps,
      MATRIX_OIDC_UPSTREAM_CONFIG: $upstream_config,
      MATRIX_POLICY_CONFIG: $policy_config
    }'
)"
printf '%s\n' "$matrix_oidc_secret_json" >"$matrix_oidc_secret_file"
chmod 600 "$matrix_oidc_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "matrix-oidc" \
  --json-file "$matrix_oidc_secret_file" \
  --required-keys "MAS_OIDC_CLIENT_ID,MAS_OIDC_CLIENT_SECRET,MAS_OIDC_PROVIDER_ULID,MATRIX_OIDC_ENABLED_IDPS,MATRIX_OIDC_UPSTREAM_CONFIG,MATRIX_POLICY_CONFIG"

# Write DB secret
matrix_db_secret_json="$(
  jq -n \
    --arg synapse_username "$matrix_synapse_db_username" \
    --arg synapse_password "$matrix_synapse_db_password" \
    --arg mas_username "$matrix_mas_db_username" \
    --arg mas_password "$matrix_mas_db_password" \
    '{
      MATRIX_SYNAPSE_POSTGRESQL__USERNAME: $synapse_username,
      MATRIX_SYNAPSE_POSTGRESQL__PASSWORD: $synapse_password,
      MATRIX_MAS_POSTGRESQL__USERNAME: $mas_username,
      MATRIX_MAS_POSTGRESQL__PASSWORD: $mas_password
    }'
)"
printf '%s\n' "$matrix_db_secret_json" >"$matrix_db_secret_file"
chmod 600 "$matrix_db_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "matrix-db" \
  --json-file "$matrix_db_secret_file" \
  --required-keys "MATRIX_SYNAPSE_POSTGRESQL__USERNAME,MATRIX_SYNAPSE_POSTGRESQL__PASSWORD,MATRIX_MAS_POSTGRESQL__USERNAME,MATRIX_MAS_POSTGRESQL__PASSWORD"

# Write runtime secret
matrix_runtime_secret_json="$(
  jq -n \
    --arg shared_secret "$synapse_shared_secret" \
    --arg encryption_secret "$mas_encryption_secret" \
    --arg signing_key "$mas_signing_key" \
    '{
      MATRIX_SYNAPSE_SHARED_SECRET: $shared_secret,
      MATRIX_MAS_ENCRYPTION_SECRET: $encryption_secret,
      MATRIX_MAS_SIGNING_KEY: $signing_key
    }'
)"
printf '%s\n' "$matrix_runtime_secret_json" >"$matrix_runtime_secret_file"
chmod 600 "$matrix_runtime_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "matrix-runtime" \
  --json-file "$matrix_runtime_secret_file" \
  --required-keys "MATRIX_SYNAPSE_SHARED_SECRET,MATRIX_MAS_ENCRYPTION_SECRET"

# Apply database manifests
databases_namespace_manifest="$WORKSPACE_ROOT/gitops/databases/shared/namespace.yaml"
matrix_synapse_db_objectstore_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-synapse/objectstore.yaml"
matrix_synapse_db_cluster_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-synapse/cluster.yaml"
matrix_synapse_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-synapse/externalsecret.yaml"
matrix_synapse_db_pooler_ro_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-synapse/pooler-ro.yaml"
matrix_synapse_db_pooler_rw_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-synapse/pooler-rw.yaml"
matrix_synapse_db_backup_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-synapse/scheduled-backup.yaml"
matrix_mas_db_objectstore_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-mas/objectstore.yaml"
matrix_mas_db_cluster_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-mas/cluster.yaml"
matrix_mas_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-mas/externalsecret.yaml"
matrix_mas_db_pooler_ro_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-mas/pooler-ro.yaml"
matrix_mas_db_pooler_rw_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-mas/pooler-rw.yaml"
matrix_mas_db_backup_manifest="$WORKSPACE_ROOT/gitops/databases/matrix-mas/scheduled-backup.yaml"
matrix_namespace_manifest="$WORKSPACE_ROOT/gitops/platform-apps/matrix/namespace.yaml"
matrix_config_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform-apps/matrix/externalsecret.yaml"
matrix_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform-apps/matrix/db-externalsecret.yaml"
matrix_runtime_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform-apps/matrix/runtime-externalsecret.yaml"

log "Applying Matrix database manifests"
kubectl apply -f "$databases_namespace_manifest"
kubectl apply -f "$matrix_synapse_db_objectstore_manifest"
kubectl apply -f "$matrix_synapse_db_cluster_manifest"
kubectl apply -f "$matrix_synapse_db_externalsecret_manifest"
kubectl apply -f "$matrix_synapse_db_pooler_ro_manifest"
kubectl apply -f "$matrix_synapse_db_pooler_rw_manifest"
kubectl apply -f "$matrix_synapse_db_backup_manifest"
kubectl apply -f "$matrix_mas_db_objectstore_manifest"
kubectl apply -f "$matrix_mas_db_cluster_manifest"
kubectl apply -f "$matrix_mas_db_externalsecret_manifest"
kubectl apply -f "$matrix_mas_db_pooler_ro_manifest"
kubectl apply -f "$matrix_mas_db_pooler_rw_manifest"
kubectl apply -f "$matrix_mas_db_backup_manifest"

wait_for_named_resource_ready "databases" "cluster" "matrix-synapse-db" "Matrix Synapse CloudNativePG cluster"
wait_for_named_resource_ready "databases" "cluster" "matrix-mas-db" "Matrix MAS CloudNativePG cluster"
wait_for_named_resource_ready "databases" "externalsecret" "matrix-synapse-db-credentials" "Matrix Synapse database ExternalSecret"
wait_for_named_resource_ready "databases" "externalsecret" "matrix-mas-db-credentials" "Matrix MAS database ExternalSecret"
wait_for_deployment_rollout "databases" "matrix-synapse-db-pooler-ro" "Matrix Synapse DB read-only pooler"
wait_for_deployment_rollout "databases" "matrix-synapse-db-pooler-rw" "Matrix Synapse DB read-write pooler"
wait_for_deployment_rollout "databases" "matrix-mas-db-pooler-ro" "Matrix MAS DB read-only pooler"
wait_for_deployment_rollout "databases" "matrix-mas-db-pooler-rw" "Matrix MAS DB read-write pooler"

# ESS pre-install hooks require these secrets before Argo CD can sync the chart.
log "Applying Matrix application secrets"
kubectl apply -f "$matrix_namespace_manifest"
kubectl apply -f "$matrix_config_externalsecret_manifest"
kubectl apply -f "$matrix_db_externalsecret_manifest"
kubectl apply -f "$matrix_runtime_externalsecret_manifest"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-config" "Matrix configuration ExternalSecret"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-synapse-db-credentials" "Matrix Synapse application DB ExternalSecret"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-mas-db-credentials" "Matrix MAS application DB ExternalSecret"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-runtime" "Matrix runtime ExternalSecret"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "matrix-synapse" \
  --host "matrix-synapse-db-pooler-rw.databases.svc.cluster.local"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "matrix-mas" \
  --host "matrix-mas-db-pooler-rw.databases.svc.cluster.local"

# Provision Authentik OIDC provider for MAS
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

provider_payload="$(
  jq -n \
    --arg name "Matrix" \
    --arg client_id "$mas_client_id" \
    --arg client_secret "$mas_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$mas_redirect_uri" \
    --arg mas_host "$mas_host" \
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
        },
        {
          matching_mode: "strict",
          url: ($mas_host + "/oidc/callback/")
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      grant_types: ["authorization_code"],
      issuer_mode: "per_provider"
    }'
)"

log "Provisioning Authentik OIDC client for Matrix"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Matrix"

application_payload="$(
  jq -n \
    --arg name "Matrix" \
    --arg slug "$mas_application_slug" \
    --arg launch_url "$mas_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Matrix"

# Apply Argo CD ApplicationSet
log "Applying Matrix Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$matrix_manifest_path" \
  --application "matrix"

# Wait for ESS resources
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-config" "Matrix configuration ExternalSecret"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-synapse-db-credentials" "Matrix Synapse database ExternalSecret"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-mas-db-credentials" "Matrix MAS database ExternalSecret"
wait_for_named_resource_ready "matrix" "externalsecret" "matrix-runtime" "Matrix runtime ExternalSecret"
wait_for_statefulset_ready "matrix" "ess-synapse-main" "Matrix Synapse"
wait_for_deployment_rollout "matrix" "ess-haproxy" "Matrix Haproxy"
wait_for_deployment_rollout "matrix" "ess-matrix-authentication-service" "Matrix MAS"
wait_for_deployment_rollout "matrix" "ess-element-web" "Element Web"
wait_for_deployment_rollout "matrix" "ess-element-admin" "Element Admin"
wait_for_deployment_rollout "matrix" "ess-matrix-rtc-authorisation-service" "Matrix RTC Authorisation"
wait_for_deployment_rollout "matrix" "ess-matrix-rtc-sfu" "Matrix RTC"

# Write step result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "matrix" \
    --arg manifest_path "$matrix_manifest_path" \
    --arg host "$matrix_host" \
    --arg chat_host "https://chat.${public_zone_name}" \
    --arg admin_host "https://element-admin.${public_zone_name}" \
    --arg mas_host "$mas_host" \
    --arg provider_pk "$provider_pk" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      host: $host,
      chat_host: $chat_host,
      admin_host: $admin_host,
      mas_host: $mas_host,
      provider_pk: $provider_pk
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "element" \
  --service-domain "chat.${public_zone_name}" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "matrix" \
  --service-domain "matrix.${public_zone_name}" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "element-admin" \
  --service-domain "element-admin.${public_zone_name}" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "matrix-account" \
  --service-domain "account.${public_zone_name}" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "matrix-rtc" \
  --service-domain "mrtc.${public_zone_name}" \
  --service-path /

log "Matrix chat installation complete"
