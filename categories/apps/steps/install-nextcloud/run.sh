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

  while true; do
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

find_scope_mapping_json_by_name_and_scope() {
  local mapping_name="$1"
  local scope_name="$2"
  local response

  response="$(authentik_api_get "/propertymappings/provider/scope/?page_size=200")"
  jq -c \
    --arg mapping_name "$mapping_name" \
    --arg scope_name "$scope_name" \
    '.results[]?
      | select((.name // "") == $mapping_name and (.scope_name // "") == $scope_name)' <<<"$response" | head -n1
}

upsert_scope_mapping() {
  local mapping_name="$1"
  local scope_name="$2"
  local description="$3"
  local expression="$4"
  local existing_json existing_pk payload

  payload="$(
    jq -n \
      --arg name "$mapping_name" \
      --arg scope_name "$scope_name" \
      --arg description "$description" \
      --arg expression "$expression" \
      '{
        name: $name,
        scope_name: $scope_name,
        description: $description,
        expression: $expression
      }'
  )"

  existing_json="$(find_scope_mapping_json_by_name_and_scope "$mapping_name" "$scope_name" || true)"
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
    [[ -n "$existing_pk" ]] || fail "Could not determine Authentik scope mapping ID for ${mapping_name}"
    authentik_api_write PATCH "/propertymappings/provider/scope/${existing_pk}/" "$payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/propertymappings/provider/scope/" "$payload" | jq -r '.pk // .id // empty'
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "Nextcloud")"
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

  existing_json="$(find_application_json_by_slug "nextcloud" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/nextcloud/" "$application_payload" >/dev/null
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

NEXTCLOUD_HOST="https://nextcloud.${public_zone_name}"
NEXTCLOUD_OIDC_REDIRECT_URI="${NEXTCLOUD_HOST}/index.php/apps/user_oidc/code"
NEXTCLOUD_OIDC_LOGOUT_URI="${NEXTCLOUD_HOST}/index.php/apps/user_oidc/sls"
NEXTCLOUD_OIDC_BACKCHANNEL_URI="${NEXTCLOUD_HOST}/index.php/apps/user_oidc/backchannel-logout/nextcloud"

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
databases_namespace_manifest="$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
nextcloud_db_cluster_manifest="$WORKSPACE_ROOT/gitops/databases/nextcloud/cluster.yaml"
nextcloud_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/databases/nextcloud/externalsecret.yaml"
nextcloud_db_pooler_ro_manifest="$WORKSPACE_ROOT/gitops/databases/nextcloud/pooler-ro.yaml"
nextcloud_db_pooler_rw_manifest="$WORKSPACE_ROOT/gitops/databases/nextcloud/pooler-rw.yaml"
nextcloud_db_backup_manifest="$WORKSPACE_ROOT/gitops/databases/nextcloud/scheduled-backup.yaml"
nextcloud_platform_dir="$WORKSPACE_ROOT/gitops/platform-apps/nextcloud"
nextcloud_app_manifest="$WORKSPACE_ROOT/gitops/apps/nextcloud.yaml"

existing_nextcloud_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_nextcloud_secret_json="$(openbao_read_global_secret_json nextcloud 2>/dev/null || true)"
fi

nextcloud_admin_username="admin"
nextcloud_admin_password="$(openssl rand -hex 24)"
nextcloud_db_username="nextcloud"
nextcloud_db_password="$(openssl rand -hex 24)"
nextcloud_redis_password="$(openssl rand -hex 24)"
nextcloud_oidc_client_id="$(openssl rand -hex 16)"
nextcloud_oidc_client_secret="$(openssl rand -hex 32)"

if [[ -n "$existing_nextcloud_secret_json" ]]; then
  nextcloud_admin_username="$(jq -r '.NEXTCLOUD_ADMIN_USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_admin_password="$(jq -r '.NEXTCLOUD_ADMIN_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_db_username="$(jq -r '.NEXTCLOUD_POSTGRESQL__USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_db_password="$(jq -r '.NEXTCLOUD_POSTGRESQL__PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_redis_password="$(jq -r '.NEXTCLOUD_REDIS_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_oidc_client_id="$(jq -r '.NEXTCLOUD_OIDC_CLIENT_ID // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_oidc_client_secret="$(jq -r '.NEXTCLOUD_OIDC_CLIENT_SECRET // empty' <<<"$existing_nextcloud_secret_json" || true)"
fi

[[ -n "$nextcloud_admin_username" ]] || nextcloud_admin_username="admin"
[[ -n "$nextcloud_admin_password" ]] || nextcloud_admin_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_db_username" ]] || nextcloud_db_username="nextcloud"
[[ -n "$nextcloud_db_password" ]] || nextcloud_db_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_redis_password" ]] || nextcloud_redis_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_oidc_client_id" ]] || nextcloud_oidc_client_id="$(openssl rand -hex 16)"
[[ -n "$nextcloud_oidc_client_secret" ]] || nextcloud_oidc_client_secret="$(openssl rand -hex 32)"

nextcloud_secret_file="$(mktemp)"
trap 'rm -f "$nextcloud_secret_file" "${nextcloud_rendered_app_manifest:-}"' EXIT
jq -n \
  --arg nextcloud_admin_username "$nextcloud_admin_username" \
  --arg nextcloud_admin_password "$nextcloud_admin_password" \
  --arg nextcloud_postgresql_username "$nextcloud_db_username" \
  --arg nextcloud_postgresql_password "$nextcloud_db_password" \
  --arg nextcloud_redis_password "$nextcloud_redis_password" \
  --arg nextcloud_oidc_client_id "$nextcloud_oidc_client_id" \
  --arg nextcloud_oidc_client_secret "$nextcloud_oidc_client_secret" \
  '{
    "NEXTCLOUD_ADMIN_USERNAME": $nextcloud_admin_username,
    "NEXTCLOUD_ADMIN_PASSWORD": $nextcloud_admin_password,
    "NEXTCLOUD_POSTGRESQL__USERNAME": $nextcloud_postgresql_username,
    "NEXTCLOUD_POSTGRESQL__PASSWORD": $nextcloud_postgresql_password,
    "NEXTCLOUD_REDIS_PASSWORD": $nextcloud_redis_password,
    "NEXTCLOUD_OIDC_CLIENT_ID": $nextcloud_oidc_client_id,
    "NEXTCLOUD_OIDC_CLIENT_SECRET": $nextcloud_oidc_client_secret
  }' >"$nextcloud_secret_file"

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"

nextcloud_profile_mapping_id="$(upsert_scope_mapping \
  "Nextcloud Profile" \
  "profile" \
  "Expose Nextcloud profile claims" \
  'groups = [group.name for group in request.user.ak_groups.all()]
return {
    "name": request.user.name,
    "preferred_username": request.user.username,
    "email": request.user.email,
    "groups": groups,
}' \
)"
[[ -n "$nextcloud_profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for Nextcloud profile"

nextcloud_groups_mapping_id="$(upsert_scope_mapping \
  "Nextcloud Groups" \
  "groups" \
  "Expose Nextcloud group membership" \
  'groups = [group.name for group in request.user.ak_groups.all()]
if request.user.is_superuser and "admin" not in groups:
    groups.append("admin")
return {
    "groups": groups,
}' \
)"
[[ -n "$nextcloud_groups_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for Nextcloud groups"

provider_payload="$(
  jq -n \
    --arg name "Nextcloud" \
    --arg client_id "$nextcloud_oidc_client_id" \
    --arg client_secret "$nextcloud_oidc_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --argjson property_mappings "$(jq -cn \
      --arg openid "$openid_mapping_id" \
      --arg email "$email_mapping_id" \
      --arg profile "$nextcloud_profile_mapping_id" \
      --arg groups "$nextcloud_groups_mapping_id" \
      '[$openid, $email, $profile, $groups]'
    )" \
    --arg redirect_login "$NEXTCLOUD_OIDC_REDIRECT_URI" \
    --arg redirect_logout "$NEXTCLOUD_OIDC_LOGOUT_URI" \
    --arg redirect_backchannel "$NEXTCLOUD_OIDC_BACKCHANNEL_URI" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $redirect_login
        },
        {
          matching_mode: "strict",
          url: $redirect_logout
        },
        {
          matching_mode: "strict",
          url: $redirect_backchannel
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      issuer_mode: "per_provider"
    }'
)"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for Nextcloud"

application_payload="$(
  jq -n \
    --arg name "Nextcloud" \
    --arg slug "nextcloud" \
    --arg launch_url "$NEXTCLOUD_HOST" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Nextcloud"

application_json="$(find_application_json_by_slug "nextcloud")"
[[ -n "$application_json" ]] || fail "Could not determine Authentik application JSON for Nextcloud"

log "Syncing Nextcloud bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "nextcloud" \
  --json-file "$nextcloud_secret_file" \
  --required-keys "NEXTCLOUD_ADMIN_USERNAME,NEXTCLOUD_ADMIN_PASSWORD,NEXTCLOUD_POSTGRESQL__USERNAME,NEXTCLOUD_POSTGRESQL__PASSWORD,NEXTCLOUD_REDIS_PASSWORD,NEXTCLOUD_OIDC_CLIENT_ID,NEXTCLOUD_OIDC_CLIENT_SECRET"

log "Applying Nextcloud namespace and secret resources"
kubectl apply -f "$nextcloud_platform_dir/namespace.yaml"
kubectl apply -f "$nextcloud_platform_dir/admin-externalsecret.yaml"
kubectl apply -f "$nextcloud_platform_dir/db-externalsecret.yaml"
kubectl apply -f "$nextcloud_platform_dir/redis-externalsecret.yaml"
kubectl apply -f "$nextcloud_platform_dir/middleware.yaml"
kubectl apply -f "$nextcloud_platform_dir/ingressroute.yaml"

wait_for_resources_ready "nextcloud" "externalsecret" "Ready" "Nextcloud ExternalSecret"

log "Applying Nextcloud database manifests"
kubectl apply -f "$databases_namespace_manifest"
kubectl apply -f "$nextcloud_db_cluster_manifest"
kubectl apply -f "$nextcloud_db_externalsecret_manifest"
kubectl apply -f "$nextcloud_db_pooler_ro_manifest"
kubectl apply -f "$nextcloud_db_pooler_rw_manifest"
kubectl apply -f "$nextcloud_db_backup_manifest"

wait_for_resources_ready "databases" "cluster" "Ready" "Nextcloud CloudNativePG cluster"
wait_for_resources_ready "databases" "externalsecret" "Ready" "Nextcloud database ExternalSecret"
wait_for_resources_ready "databases" "deployment" "Available" "Nextcloud pooler deployment"

nextcloud_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/nextcloud-${cluster_id}.XXXXXX.yaml")"
# Keep trustedDomains aligned with the runtime host we render into the Argo app.
sed \
  -e "s|__REPO_URL__|${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}|g" \
  -e "s|__TARGET_REVISION__|${TWINBOX_GIT_TARGET_REVISION:-main}|g" \
  -e "s|__NEXTCLOUD_HOST__|${NEXTCLOUD_HOST}|g" \
  "$nextcloud_app_manifest" >"$nextcloud_rendered_app_manifest"

log "Applying Nextcloud Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$nextcloud_rendered_app_manifest" \
  --application "nextcloud"

wait_for_deployment_rollout "nextcloud" "nextcloud" "Nextcloud application"
wait_for_statefulset_ready "nextcloud" "nextcloud-redis-master" "Nextcloud Redis master"

log "Bootstrapping Nextcloud user_oidc"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
  set -euo pipefail
  cd /var/www/html
  php occ app:install user_oidc >/dev/null 2>&1 || true
  php occ app:enable user_oidc >/dev/null
  php occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends
  php occ user_oidc:provider nextcloud \
    --clientid='${nextcloud_oidc_client_id}' \
    --clientsecret='${nextcloud_oidc_client_secret}' \
    --discoveryuri='${AUTHENTIK_HOST%/}/application/o/nextcloud/.well-known/openid-configuration' \
    --endsessionendpointuri='${AUTHENTIK_HOST%/}/application/o/nextcloud/end-session/' \
    --postlogouturi='${NEXTCLOUD_HOST}' \
    --scope='openid email profile groups' \
    --mapping-display-name='name' \
    --mapping-email='email' \
    --mapping-uid='preferred_username' \
    --mapping-groups='groups' \
    --group-provisioning='0' \
    --group-restrict-login-to-whitelist='0' \
    --unique-uid='1' \
    --check-bearer='0' \
    --bearer-provisioning='0' \
    --send-id-token-hint='1' \
    --resolve-nested-claims='1'
"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg application "nextcloud" \
    --arg database "nextcloud-db" \
    --arg public_url "$NEXTCLOUD_HOST" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      database: $database,
      public_url: $public_url
    }' >"$STEP_RESULT_FILE"
fi
