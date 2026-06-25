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

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"

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
cluster_scope_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_scope_id" ]] || fail "Could not determine cluster scope ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

zulip_default_realm_owner_email="admin@${public_zone_name}"
zulip_default_realm_owner_name="Twinbox Admin"
zulip_jitsi_server_url="https://jitsi.${public_zone_name}"
create_users_state_file="$MANAGER_DATA_DIR/step-state/clusters/${cluster_scope_id}/create-users-and-groups.json"
if [[ -f "$create_users_state_file" ]]; then
  step_owner_email="$(jq -r '.outputs.email // empty' "$create_users_state_file")"
  step_owner_name="$(jq -r '.outputs.full_name // empty' "$create_users_state_file")"
  if [[ -n "$step_owner_email" ]]; then
    zulip_default_realm_owner_email="$step_owner_email"
  fi
  if [[ -n "$step_owner_name" ]]; then
    zulip_default_realm_owner_name="$step_owner_name"
  fi
fi

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
zulip_host="https://zulip.${public_zone_name}"
zulip_redirect_uri="${zulip_host}/complete/oidc/"
zulip_application_slug="zulip"
zulip_issuer_url="${AUTHENTIK_HOST%/}/application/o/${zulip_application_slug}/"
zulip_agent_base_url="${ZULIP_AGENT_BASE_URL:-$zulip_host}"
zulip_provisioning_base_url="${ZULIP_PROVISIONING_BASE_URL:-http://127.0.0.1}"
zulip_agent_stream="${ZULIP_AGENT_STREAM:-Twinbox AI}"
zulip_agent_bot_short_name="${ZULIP_AGENT_BOT_SHORT_NAME:-olivia-ops}"
zulip_agent_bot_full_name="${ZULIP_AGENT_BOT_FULL_NAME:-Olivia Ops}"
agents_namespace="${AGENTS_NAMESPACE:-twinbox-agents}"
zulip_client_id="$(openssl rand -hex 16)"
zulip_client_secret="$(openssl rand -hex 24)"
zulip_secret_key="$(openssl rand -hex 32)"
zulip_db_username="zulip"
zulip_db_password="$(openssl rand -hex 24)"
zulip_rabbitmq_password="$(openssl rand -hex 24)"
zulip_rabbitmq_erlang_cookie="$(openssl rand -hex 24)"
zulip_redis_password="$(openssl rand -hex 24)"
zulip_memcached_password="$(openssl rand -hex 24)"
secrets_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"
zulip_secret_file="${secrets_dir}/zulip-oidc-${cluster_id}.json"
zulip_runtime_secret_file="${secrets_dir}/zulip-runtime-${cluster_id}.json"
agents_secret_file="${secrets_dir}/twinbox-agents.json"
zulip_manifest_path="$WORKSPACE_ROOT/gitops/optional-apps/zulip.yaml"
trap 'rm -f "$zulip_secret_file" "$zulip_runtime_secret_file"' EXIT

mkdir -p "$secrets_dir"

existing_zulip_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_zulip_secret_json="$(openbao_read_global_secret_json zulip-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_zulip_secret_json" ]]; then
  existing_client_id="$(jq -r '.ZULIP_OIDC_CLIENT_ID // empty' <<<"$existing_zulip_secret_json")"
  existing_client_secret="$(jq -r '.ZULIP_OIDC_CLIENT_SECRET // empty' <<<"$existing_zulip_secret_json")"
  existing_secret_key="$(jq -r '.SECRETS_secret_key // empty' <<<"$existing_zulip_secret_json")"
  existing_db_username="$(jq -r '.ZULIP_POSTGRESQL__USERNAME // empty' <<<"$existing_zulip_secret_json")"
  existing_db_password="$(jq -r '.ZULIP_POSTGRESQL__PASSWORD // empty' <<<"$existing_zulip_secret_json")"
  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    zulip_client_id="$existing_client_id"
    zulip_client_secret="$existing_client_secret"
  fi
  if [[ -n "$existing_secret_key" ]]; then
    zulip_secret_key="$existing_secret_key"
  fi
  if [[ -n "$existing_db_username" ]]; then
    zulip_db_username="$existing_db_username"
  fi
  if [[ -n "$existing_db_password" ]]; then
    zulip_db_password="$existing_db_password"
  fi
fi

existing_zulip_runtime_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_zulip_runtime_secret_json="$(openbao_read_global_secret_json zulip-runtime 2>/dev/null || true)"
fi

if [[ -n "$existing_zulip_runtime_secret_json" ]]; then
  existing_rabbitmq_password="$(jq -r '.ZULIP_RABBITMQ_PASSWORD // empty' <<<"$existing_zulip_runtime_secret_json")"
  existing_redis_password="$(jq -r '.ZULIP_REDIS_PASSWORD // empty' <<<"$existing_zulip_runtime_secret_json")"
  existing_erlang_cookie="$(jq -r '.ZULIP_RABBITMQ_ERLANG_COOKIE // empty' <<<"$existing_zulip_runtime_secret_json")"
  existing_memcached_password="$(jq -r '.ZULIP_MEMCACHED_PASSWORD // empty' <<<"$existing_zulip_runtime_secret_json")"
  if [[ -n "$existing_rabbitmq_password" ]]; then
    zulip_rabbitmq_password="$existing_rabbitmq_password"
  fi
  if [[ -n "$existing_redis_password" ]]; then
    zulip_redis_password="$existing_redis_password"
  fi
  if [[ -n "$existing_erlang_cookie" ]]; then
    zulip_rabbitmq_erlang_cookie="$existing_erlang_cookie"
  fi
  if [[ -n "$existing_memcached_password" ]]; then
    zulip_memcached_password="$existing_memcached_password"
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
    --arg db_username "$zulip_db_username" \
    --arg db_password "$zulip_db_password" \
    --arg owner_email "$zulip_default_realm_owner_email" \
    --arg owner_name "$zulip_default_realm_owner_name" \
    --arg oidc_idps "$zulip_oidc_idps_literal" \
    '{
      SECRETS_secret_key: $secret_key,
      ZULIP_OIDC_CLIENT_ID: $client_id,
      ZULIP_OIDC_CLIENT_SECRET: $client_secret,
      ZULIP_POSTGRESQL__USERNAME: $db_username,
      ZULIP_POSTGRESQL__PASSWORD: $db_password,
      ZULIP_DEFAULT_REALM_OWNER_EMAIL: $owner_email,
      ZULIP_DEFAULT_REALM_OWNER_NAME: $owner_name,
      SETTING_SOCIAL_AUTH_OIDC_ENABLED_IDPS: $oidc_idps
    }'
)"
printf '%s\n' "$zulip_config_secret_json" >"$zulip_secret_file"
chmod 600 "$zulip_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "zulip-oidc" \
  --json-file "$zulip_secret_file" \
  --required-keys "SECRETS_secret_key,SETTING_SOCIAL_AUTH_OIDC_ENABLED_IDPS,ZULIP_POSTGRESQL__USERNAME,ZULIP_POSTGRESQL__PASSWORD"

zulip_runtime_secret_json="$(
  jq -n \
    --arg rabbitmq_password "$zulip_rabbitmq_password" \
    --arg redis_password "$zulip_redis_password" \
    --arg erlang_cookie "$zulip_rabbitmq_erlang_cookie" \
    --arg memcached_password "$zulip_memcached_password" \
    '{
      ZULIP_RABBITMQ_PASSWORD: $rabbitmq_password,
      ZULIP_RABBITMQ_ERLANG_COOKIE: $erlang_cookie,
      ZULIP_REDIS_PASSWORD: $redis_password,
      ZULIP_MEMCACHED_PASSWORD: $memcached_password
    }'
)"
printf '%s\n' "$zulip_runtime_secret_json" >"$zulip_runtime_secret_file"
chmod 600 "$zulip_runtime_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "zulip-runtime" \
  --json-file "$zulip_runtime_secret_file" \
  --required-keys "ZULIP_RABBITMQ_PASSWORD,ZULIP_RABBITMQ_ERLANG_COOKIE,ZULIP_REDIS_PASSWORD,ZULIP_MEMCACHED_PASSWORD"

databases_namespace_manifest="$WORKSPACE_ROOT/gitops/databases/shared/namespace.yaml"
zulip_db_objectstore_manifest="$WORKSPACE_ROOT/gitops/databases/zulip/objectstore.yaml"
zulip_db_cluster_manifest="$WORKSPACE_ROOT/gitops/databases/zulip/cluster.yaml"
zulip_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/databases/zulip/externalsecret.yaml"
zulip_db_pooler_ro_manifest="$WORKSPACE_ROOT/gitops/databases/zulip/pooler-ro.yaml"
zulip_db_pooler_rw_manifest="$WORKSPACE_ROOT/gitops/databases/zulip/pooler-rw.yaml"
zulip_db_backup_manifest="$WORKSPACE_ROOT/gitops/databases/zulip/scheduled-backup.yaml"

log "Applying Zulip database manifests"
kubectl apply -f "$databases_namespace_manifest"
kubectl apply -f "$zulip_db_objectstore_manifest"
kubectl apply -f "$zulip_db_cluster_manifest"
kubectl apply -f "$zulip_db_externalsecret_manifest"
kubectl apply -f "$zulip_db_pooler_ro_manifest"
kubectl apply -f "$zulip_db_pooler_rw_manifest"
kubectl apply -f "$zulip_db_backup_manifest"

wait_for_named_resource_ready "databases" "cluster" "zulip-db" "Zulip CloudNativePG cluster"
wait_for_named_resource_ready "databases" "externalsecret" "zulip-db-credentials" "Zulip database ExternalSecret"
wait_for_deployment_rollout "databases" "zulip-db-pooler-ro" "Zulip read-only pooler"
wait_for_deployment_rollout "databases" "zulip-db-pooler-rw" "Zulip read-write pooler"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "zulip" \
  --host "zulip-db-pooler-rw.databases.svc.cluster.local"

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
      grant_types: ["authorization_code"],
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Zulip Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$zulip_manifest_path" \
  --application "zulip"

wait_for_named_resource_ready "zulip" "externalsecret" "zulip-config" "Zulip config ExternalSecret"
wait_for_named_resource_ready "zulip" "externalsecret" "zulip-db-credentials" "Zulip database credentials ExternalSecret"
wait_for_named_resource_ready "zulip" "externalsecret" "zulip-runtime" "Zulip runtime ExternalSecret"
wait_for_statefulset_ready "zulip" "zulip-rabbitmq" "Zulip RabbitMQ"
wait_for_statefulset_ready "zulip" "zulip-redis-master" "Zulip Redis master"
wait_for_deployment_rollout "zulip" "zulip-memcached" "Zulip memcached"
wait_for_statefulset_ready "zulip" "zulip" "Zulip application"

find_statefulset_pod() {
  local namespace="$1"
  local statefulset="$2"
  local statefulset_json selector

  statefulset_json="$(kubectl -n "$namespace" get statefulset "$statefulset" -o json 2>/dev/null)" || return 1
  selector="$(
    jq -r '
      .spec.selector.matchLabels
      | to_entries
      | map("\(.key)=\(.value)")
      | join(",")
    ' <<<"$statefulset_json"
  )"

  [[ -n "$selector" ]] || return 1
  kubectl -n "$namespace" get pods -l "$selector" -o json |
    jq -r '
      .items[]
      | select((.status.phase // "") == "Running")
      | .metadata.name
    ' | head -n1
}

verify_zulip_bootstrap() {
  local pod_name expected_owner_email_json expected_jitsi_server_url_json
  local verify_script

  pod_name="$(find_statefulset_pod "zulip" "zulip")"
  [[ -n "$pod_name" ]] || fail "Could not find a running Zulip pod for bootstrap verification"

  verify_script="$(
    cat <<'PY'
from zerver.models import DefaultStream, OnboardingUserMessage, Realm, Stream, UserProfile

realm = Realm.objects.get(string_id="")

expected_jitsi_server_url = __JITSI_SERVER_URL_JSON__
if realm.jitsi_server_url != expected_jitsi_server_url:
    raise SystemExit(
        f"Unexpected Zulip Jitsi server URL: {realm.jitsi_server_url!r} != {expected_jitsi_server_url!r}"
    )

if realm.video_chat_provider != Realm.VIDEO_CHAT_PROVIDERS["jitsi_meet"]["id"]:
    raise SystemExit("Zulip video chat provider is not configured for Jitsi Meet")

required_streams = ["Zulip", "sandbox", "general", "announcements", "support"]
missing_streams = [
    stream_name
    for stream_name in required_streams
    if not Stream.objects.filter(realm=realm, name=stream_name).exists()
]
if missing_streams:
    raise SystemExit(f"Missing Zulip streams: {', '.join(missing_streams)}")

missing_default_streams = [
    stream_name
    for stream_name in required_streams
    if not DefaultStream.objects.filter(realm=realm, stream__name=stream_name).exists()
]
if missing_default_streams:
    raise SystemExit(f"Missing Zulip default streams: {', '.join(missing_default_streams)}")

owner_email = __OWNER_EMAIL_JSON__
if not UserProfile.objects.filter(
    realm=realm,
    delivery_email__iexact=owner_email,
    role=UserProfile.ROLE_REALM_OWNER,
    is_active=True,
).exists():
    raise SystemExit(f"Missing active Zulip realm owner with email {owner_email}")

if not OnboardingUserMessage.objects.filter(realm_id=realm.id).exists():
    raise SystemExit("Missing Zulip onboarding messages")

print("Zulip bootstrap verified")
PY
  )"

  expected_owner_email_json="$(jq -n --arg value "$zulip_default_realm_owner_email" '$value')"
  expected_jitsi_server_url_json="$(jq -n --arg value "$zulip_jitsi_server_url" '$value')"
  verify_script="${verify_script/__OWNER_EMAIL_JSON__/$expected_owner_email_json}"
  verify_script="${verify_script/__JITSI_SERVER_URL_JSON__/$expected_jitsi_server_url_json}"

  kubectl -n zulip exec "$pod_name" -- bash -c "
cat > /tmp/verify-bootstrap.py << 'VERIFYEOF'
$verify_script
VERIFYEOF
su zulip -c '/home/zulip/deployments/current/manage.py shell -c \"\$(cat /tmp/verify-bootstrap.py)\"'
" >/dev/null
  log "Zulip bootstrap verified"
}

read_zulip_owner_api_credentials() {
  local pod_name="$1"
  local owner_email="$2"

  kubectl -n zulip exec -i "$pod_name" -- env OWNER_EMAIL="$owner_email" bash -s <<'POD_SCRIPT'
set -euo pipefail
: "${OWNER_EMAIL:?missing OWNER_EMAIL}"
: "${SECRETS_postgres_password:?missing database password}"
: "${SETTING_REMOTE_POSTGRES_HOST:?missing database host}"
: "${CONFIG_postgresql__database_user:?missing database user}"
: "${CONFIG_postgresql__database_name:?missing database name}"
field_separator="$(printf "\t")"
owner_email_sql="$(printf '%s' "$OWNER_EMAIL" | sed "s/'/''/g")"
PGPASSWORD="$SECRETS_postgres_password" psql \
  -h "$SETTING_REMOTE_POSTGRES_HOST" \
  -p "${SETTING_REMOTE_POSTGRES_PORT:-5432}" \
  -U "$CONFIG_postgresql__database_user" \
  -d "$CONFIG_postgresql__database_name" \
  -v ON_ERROR_STOP=1 \
  -tA \
  -F "$field_separator" \
  -c "SELECT delivery_email, api_key FROM zerver_userprofile WHERE lower(delivery_email) = lower('${owner_email_sql}') AND is_active = true AND is_bot = false ORDER BY id LIMIT 1;"
POD_SCRIPT
}

sync_zulip_bot_to_agents_secret() {
  local bot_email="$1"
  local bot_api_key="$2"
  local current_agents_secret_json tmp_agents_secret_json

  tmp_agents_secret_json="$(mktemp "${TMPDIR:-/tmp}/twinbox-agents-zulip-XXXXXX")"

  if [[ -s "$agents_secret_file" ]]; then
    cp "$agents_secret_file" "$tmp_agents_secret_json"
  else
    current_agents_secret_json=""
    if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
      current_agents_secret_json="$(openbao_read_global_secret_json twinbox-agents 2>/dev/null || true)"
    fi
    if [[ -n "$current_agents_secret_json" ]]; then
      printf '%s\n' "$current_agents_secret_json" >"$tmp_agents_secret_json"
    else
      printf '{}\n' >"$tmp_agents_secret_json"
    fi
  fi

  jq -e 'type == "object"' "$tmp_agents_secret_json" >/dev/null \
    || fail "Existing Twinbox agents secret is not a JSON object"

  jq \
    --arg base_url "$zulip_agent_base_url" \
    --arg bot_email "$bot_email" \
    --arg bot_api_key "$bot_api_key" \
    --arg stream "$zulip_agent_stream" \
    '. + {
      ZULIP_BASE_URL: $base_url,
      ZULIP_BOT_EMAIL: $bot_email,
      ZULIP_BOT_API_KEY: $bot_api_key,
      ZULIP_STREAM: $stream
    }' \
    "$tmp_agents_secret_json" >"${tmp_agents_secret_json}.next"

  mv "${tmp_agents_secret_json}.next" "$agents_secret_file"
  rm -f "$tmp_agents_secret_json"
  chmod 600 "$agents_secret_file"

  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "twinbox-agents" \
    --json-file "$agents_secret_file" \
    --required-keys "ZULIP_BASE_URL,ZULIP_BOT_EMAIL,ZULIP_BOT_API_KEY,ZULIP_STREAM"
}

refresh_twinbox_agents_zulip_secret() {
  if kubectl -n "$agents_namespace" get externalsecret/twinbox-agents-runtime >/dev/null 2>&1; then
    local refresh_stamp
    refresh_stamp="$(date +%s)"
    kubectl -n "$agents_namespace" annotate externalsecret/twinbox-agents-runtime \
      twinbox.io/force-sync="$refresh_stamp" --overwrite >/dev/null 2>&1 || true
    kubectl -n "$agents_namespace" wait \
      --for=condition=Ready externalsecret/twinbox-agents-runtime \
      --timeout=10m
  fi

  if kubectl -n "$agents_namespace" get deployment/twinbox-agents >/dev/null 2>&1; then
    kubectl -n "$agents_namespace" rollout restart deployment/twinbox-agents
    kubectl -n "$agents_namespace" rollout status deployment/twinbox-agents --timeout=10m
  fi
}

ensure_zulip_agent_bot() {
  local pod_name owner_credentials owner_auth_email owner_api_key
  local subscriptions_json subscription_response bots_json bot_json
  local bot_email bot_api_key create_response

  pod_name="$(find_statefulset_pod "zulip" "zulip")"
  [[ -n "$pod_name" ]] || fail "Could not find a running Zulip pod for agent bot setup"

  owner_credentials="$(read_zulip_owner_api_credentials "$pod_name" "$zulip_default_realm_owner_email")"
  owner_auth_email="$(printf '%s\n' "$owner_credentials" | awk -F '\t' 'NF >= 2 {print $1; exit}')"
  owner_api_key="$(printf '%s\n' "$owner_credentials" | awk -F '\t' 'NF >= 2 {print $2; exit}')"
  [[ -n "$owner_auth_email" && -n "$owner_api_key" ]] \
    || fail "Could not resolve Zulip realm owner API credentials"

  log "Ensuring Zulip stream ${zulip_agent_stream} exists for Twinbox agents"
  subscriptions_json="$(
    jq -cn \
      --arg name "$zulip_agent_stream" \
      --arg description "AI beheerteam work order reports from Olivia Ops." \
      '[{name: $name, description: $description}]'
  )"
  subscription_response="$(
    kubectl -n zulip exec "$pod_name" -- env \
      OWNER_AUTH_EMAIL="$owner_auth_email" \
      OWNER_API_KEY="$owner_api_key" \
      ZULIP_API_BASE_URL="$zulip_provisioning_base_url" \
      SUBSCRIPTIONS_JSON="$subscriptions_json" \
      bash -lc '
set -euo pipefail
curl -fsS \
  -u "${OWNER_AUTH_EMAIL}:${OWNER_API_KEY}" \
  --data-urlencode "subscriptions=${SUBSCRIPTIONS_JSON}" \
  "${ZULIP_API_BASE_URL%/}/api/v1/users/me/subscriptions"
'
  )" || fail "Could not ensure Zulip stream ${zulip_agent_stream}"
  jq -e '.result == "success"' >/dev/null <<<"$subscription_response" \
    || fail "Zulip stream setup failed"

  bots_json="$(
    kubectl -n zulip exec "$pod_name" -- env \
      OWNER_AUTH_EMAIL="$owner_auth_email" \
      OWNER_API_KEY="$owner_api_key" \
      ZULIP_API_BASE_URL="$zulip_provisioning_base_url" \
      bash -lc '
set -euo pipefail
curl -fsS -u "${OWNER_AUTH_EMAIL}:${OWNER_API_KEY}" "${ZULIP_API_BASE_URL%/}/api/v1/bots"
'
  )" || fail "Could not list Zulip bots"
  bot_json="$(
    jq -c \
      --arg prefix "${zulip_agent_bot_short_name}-bot@" \
      '.bots[]? | select((.username // "") | startswith($prefix))' \
      <<<"$bots_json" | head -n1
  )"

  if [[ -z "$bot_json" ]]; then
    log "Creating Zulip bot ${zulip_agent_bot_full_name} for Twinbox agents"
    create_response="$(
      kubectl -n zulip exec "$pod_name" -- env \
        OWNER_AUTH_EMAIL="$owner_auth_email" \
        OWNER_API_KEY="$owner_api_key" \
        ZULIP_API_BASE_URL="$zulip_provisioning_base_url" \
        BOT_SHORT_NAME="$zulip_agent_bot_short_name" \
        BOT_FULL_NAME="$zulip_agent_bot_full_name" \
        BOT_STREAM="$zulip_agent_stream" \
        bash -lc '
set -euo pipefail
curl -fsS \
  -u "${OWNER_AUTH_EMAIL}:${OWNER_API_KEY}" \
  -X POST \
  --data-urlencode "short_name=${BOT_SHORT_NAME}" \
  --data-urlencode "full_name=${BOT_FULL_NAME}" \
  --data-urlencode "bot_type=1" \
  --data-urlencode "default_sending_stream=${BOT_STREAM}" \
  "${ZULIP_API_BASE_URL%/}/api/v1/bots"
'
    )" || fail "Could not create Zulip bot ${zulip_agent_bot_full_name}"
    jq -e '.result == "success"' >/dev/null <<<"$create_response" \
      || fail "Zulip bot creation failed"

    bots_json="$(
      kubectl -n zulip exec "$pod_name" -- env \
        OWNER_AUTH_EMAIL="$owner_auth_email" \
        OWNER_API_KEY="$owner_api_key" \
        ZULIP_API_BASE_URL="$zulip_provisioning_base_url" \
        bash -lc '
set -euo pipefail
curl -fsS -u "${OWNER_AUTH_EMAIL}:${OWNER_API_KEY}" "${ZULIP_API_BASE_URL%/}/api/v1/bots"
'
    )" || fail "Could not list Zulip bots after creation"
    bot_json="$(
      jq -c \
        --arg prefix "${zulip_agent_bot_short_name}-bot@" \
        '.bots[]? | select((.username // "") | startswith($prefix))' \
        <<<"$bots_json" | head -n1
    )"
  else
    log "Reusing existing Zulip bot ${zulip_agent_bot_full_name}"
  fi

  bot_email="$(jq -r '.username // empty' <<<"$bot_json")"
  bot_api_key="$(jq -r '.api_key // empty' <<<"$bot_json")"
  [[ -n "$bot_email" && -n "$bot_api_key" ]] \
    || fail "Could not resolve Zulip bot credentials for Twinbox agents"

  log "Syncing Zulip bot credentials into Twinbox agents runtime secret"
  sync_zulip_bot_to_agents_secret "$bot_email" "$bot_api_key"
  refresh_twinbox_agents_zulip_secret
  log "Twinbox agents Zulip integration is configured for stream ${zulip_agent_stream}"
}

ensure_zulip_bootstrap_streams() {
  local pod_name bootstrap_script

  pod_name="$(find_statefulset_pod "zulip" "zulip")"
  [[ -n "$pod_name" ]] || fail "Could not find a running Zulip pod for bootstrap stream setup"

  bootstrap_script="$(
    cat <<'PY'
from zerver.actions.default_streams import do_add_default_stream
from zerver.lib.onboarding import send_initial_realm_messages
from zerver.lib.streams import ensure_stream
from zerver.models import DefaultStream, OnboardingUserMessage, Realm, Stream

realm = Realm.objects.get(string_id="")
desired_jitsi_server_url = __JITSI_SERVER_URL_JSON__

update_fields = []
if realm.jitsi_server_url != desired_jitsi_server_url:
    realm.jitsi_server_url = desired_jitsi_server_url
    update_fields.append("jitsi_server_url")

desired_video_chat_provider = Realm.VIDEO_CHAT_PROVIDERS["jitsi_meet"]["id"]
if realm.video_chat_provider != desired_video_chat_provider:
    realm.video_chat_provider = desired_video_chat_provider
    update_fields.append("video_chat_provider")

if update_fields:
    realm.save(update_fields=update_fields)

streams = {
    "general": "General conversation for the Twinbox cluster.",
    "announcements": "Announcements and release notes for Twinbox.",
    "support": "Questions, setup help, and troubleshooting.",
}

for stream_name, stream_description in streams.items():
    stream = ensure_stream(
        realm, stream_name, stream_description=stream_description, acting_user=None
    )
    do_add_default_stream(stream)

if not OnboardingUserMessage.objects.filter(realm_id=realm.id).exists():
    send_initial_realm_messages(realm)

required_default_streams = sorted(streams)
missing_default_streams = [
    stream_name
    for stream_name in required_default_streams
    if not DefaultStream.objects.filter(realm=realm, stream__name=stream_name).exists()
]
if missing_default_streams:
    raise SystemExit(f"Missing default streams: {', '.join(missing_default_streams)}")

missing_streams = [
    stream_name
    for stream_name in required_default_streams
    if not Stream.objects.filter(realm=realm, name=stream_name).exists()
]
if missing_streams:
    raise SystemExit(f"Missing streams: {', '.join(missing_streams)}")

print("Zulip bootstrap streams and onboarding are present")
PY
  )"

  bootstrap_script="${bootstrap_script/__JITSI_SERVER_URL_JSON__/$(jq -n --arg value "$zulip_jitsi_server_url" '$value')}"

  kubectl -n zulip exec "$pod_name" -- bash -c "
cat > /tmp/ensure-zulip-bootstrap.py << 'BOOTSTRAPEOF'
$bootstrap_script
BOOTSTRAPEOF
su zulip -c '/home/zulip/deployments/current/manage.py shell < /tmp/ensure-zulip-bootstrap.py'
" >/dev/null
  log "Zulip bootstrap streams and Jitsi configuration are present"
}

wait_for_zulip_realm() {
  local pod_name realm_exists
  local attempts=24
  local attempt=1

  pod_name="$1"
  while [[ "$attempt" -le "$attempts" ]]; do
    realm_exists="$(
      kubectl -n zulip exec "$pod_name" -- bash -c 'su zulip -c "cd /home/zulip/deployments/current && ./manage.py shell -c '\''from zerver.models import Realm; print(\"yes\" if Realm.objects.count() else \"no\")'\''"' 2>/dev/null | tail -n1
    )"

    if [[ "$realm_exists" == "yes" ]]; then
      log "Zulip default realm exists"
      return 0
    fi

    if [[ "$((attempt % 6))" == "0" ]]; then
      log "Waiting for Zulip default realm to be created by postSetup ($((attempt * 5))s)"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done

  log "Creating Zulip default realm (postSetup may not have run)"
  local realm_name="Twinbox"
  local create_script
  create_script="$(cat <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
cd /home/zulip/deployments/current
su zulip -c "./manage.py create_realm --automated --string-id= '${realm_name}' '${zulip_default_realm_owner_email}' '${zulip_default_realm_owner_name}'"
SCRIPTEOF
  )"

  kubectl -n zulip exec "$pod_name" -- bash -c "cat > /tmp/create-realm.sh << 'INNEREOF'
${create_script}
INNEREOF
bash /tmp/create-realm.sh
" >/dev/null

  realm_exists="$(
    kubectl -n zulip exec "$pod_name" -- bash -c 'su zulip -c "cd /home/zulip/deployments/current && ./manage.py shell -c '\''from zerver.models import Realm; print(\"yes\" if Realm.objects.count() else \"no\")'\''"' 2>/dev/null | tail -n1
  )"

  if [[ "$realm_exists" != "yes" ]]; then
    fail "Failed to create Zulip default realm"
  fi

  log "Zulip default realm created"
}

zulip_realm_pod="$(find_statefulset_pod "zulip" "zulip")"
[[ -n "$zulip_realm_pod" ]] || fail "Could not find running Zulip pod for realm existence check"
wait_for_zulip_realm "$zulip_realm_pod"
ensure_zulip_bootstrap_streams
verify_zulip_bootstrap
ensure_zulip_agent_bot

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "zulip" \
    --arg manifest_path "$zulip_manifest_path" \
    --arg host "$zulip_host" \
    --arg database "zulip-db" \
    --arg provider_pk "$provider_pk" \
    --arg agent_stream "$zulip_agent_stream" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      host: $host,
      database: $database,
      provider_pk: $provider_pk,
      agent_stream: $agent_stream
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "zulip" \
  --service-domain "zulip.${public_zone_name}" \
  --service-path /
