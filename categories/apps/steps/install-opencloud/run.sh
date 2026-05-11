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
  local status_json desired_replicas updated_replicas ready_replicas available_replicas progressing_status progressing_reason available_status available_reason message

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
      local pod_status_json pod_summaries
      pod_status_json="$(kubectl -n "$namespace" get pods -l "app.kubernetes.io/name=${statefulset}" -o json 2>/dev/null || true)"
      if [[ -n "$pod_status_json" ]]; then
        pod_summaries="$(
          jq -r '
            .items[]? |
            .metadata.name as $name |
            ($name + ":" + (.status.phase // "Unknown") +
              (
                (
                  [.status.initContainerStatuses[]? | select(.ready != true) |
                    (.name + "=" + (.state.waiting.reason // .state.terminated.reason // "init-not-ready"))
                  ] +
                  [.status.containerStatuses[]? | select(.ready != true) |
                    (.name + "=" + (.state.waiting.reason // .state.terminated.reason // "not-ready"))
                  ]
                ) | if length > 0 then " [" + join(", ") + "]" else "" end
              )
            )
          ' <<<"$pod_status_json" | awk 'NF { if (out) out = out " | "; out = out $0 } END { print out }'
        )"
      fi
      log "Waiting for ${label} (${attempt}/${attempts}): ready=${ready_replicas}, desired=${replicas}${pod_summaries:+, pods=${pod_summaries}}"
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

wait_for_opencloud_ldap_directory() {
  local attempts=60
  local attempt=1

  while true; do
    if kubectl -n opencloud exec opencloud-ldap-0 -c ldap -- env LDAPTLS_REQCERT=never sh -ec '
      ldapsearch -H ldaps://127.0.0.1:1636 -x -D "cn=admin,dc=opencloud,dc=eu" -w "$LDAP_ADMIN_PASSWORD" -b "ou=users,dc=opencloud,dc=eu" -s base dn >/dev/null &&
      ldapsearch -H ldaps://127.0.0.1:1636 -x -D "cn=admin,dc=opencloud,dc=eu" -w "$LDAP_ADMIN_PASSWORD" -b "ou=groups,dc=opencloud,dc=eu" -s base dn >/dev/null
    ' >/dev/null 2>&1; then
      log "OpenCloud LDAP directory responds to bind/search"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "OpenCloud LDAP directory did not become searchable"
    fi

    log "Waiting for OpenCloud LDAP directory bind/search (${attempt}/${attempts})"
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
  local payload existing_json existing_pk

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
  local provider_name="$1"
  local provider_slug="$2"
  local provider_payload="$3"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

render_opencloud_overlay() {
  local source_dir="$1"
  local rendered_dir="$2"
  local zone_name="$3"

  python3 - "$source_dir" "$rendered_dir" "$zone_name" <<'PY'
from pathlib import Path
import sys

source_dir = Path(sys.argv[1])
rendered_dir = Path(sys.argv[2])
zone_name = sys.argv[3]

for path in source_dir.rglob('*'):
    target = rendered_dir / path.relative_to(source_dir)
    if path.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(path.read_text(encoding='utf-8').replace('__ZONE_NAME__', zone_name), encoding='utf-8')
PY
}

resolve_cluster_json() {
  printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster'
}

cluster_json="$(resolve_cluster_json)"
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
OPENCLOUD_HOST="https://opencloud.${public_zone_name}"
COLLABORA_HOST="https://opencloud-collabora.${public_zone_name}"
WOPISERVER_HOST="https://opencloud-wopiserver.${public_zone_name}"

existing_opencloud_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_opencloud_secret_json="$(openbao_read_global_secret_json opencloud 2>/dev/null || true)"
fi

opencloud_oc_url="${OPENCLOUD_HOST}"
opencloud_oc_oidc_issuer="${AUTHENTIK_HOST}/"
opencloud_web_edit_link="${AUTHENTIK_HOST}/if/user/"
opencloud_oc_jwt_secret="$(openssl rand -hex 32)"
opencloud_wopi_secret="$(openssl rand -hex 32)"
opencloud_collaboration_wopi_src="$WOPISERVER_HOST"
opencloud_idm_admin_password="$(openssl rand -hex 24)"
opencloud_ldap_bind_password="$(openssl rand -hex 24)"
opencloud_collabora_admin_password="$(openssl rand -hex 24)"
opencloud_collabora_admin_user="admin"
opencloud_collabora_domain="$COLLABORA_HOST"
opencloud_companion_domain="$OPENCLOUD_HOST"
opencloud_idp_domain="$AUTHENTIK_HOST"
opencloud_reva_gateway="opencloud"
opencloud_micro_registry_address="opencloud:9233"
opencloud_collaboration_app_name="CollaboraOnline"
opencloud_collaboration_app_product="Collabora"
opencloud_collaboration_app_addr="$COLLABORA_HOST"
opencloud_collaboration_app_icon="${COLLABORA_HOST}/favicon.ico"
opencloud_collaboration_app_insecure="true"
opencloud_collaboration_cs3api_datagateway_insecure="true"
opencloud_oc_ldap_bind_dn="cn=admin,dc=opencloud,dc=eu"
opencloud_oc_ldap_uri="ldaps://opencloud-ldap:1636"
opencloud_oc_ldap_user_base_dn="ou=users,dc=opencloud,dc=eu"
opencloud_oc_ldap_group_base_dn="ou=groups,dc=opencloud,dc=eu"
opencloud_oc_ldap_user_filter="(objectclass=inetOrgPerson)"
opencloud_oc_ldap_user_schema_id="opencloudUUID"
opencloud_oc_ldap_group_schema_id="opencloudUUID"
opencloud_oc_ldap_disable_user_mechanism="none"
opencloud_oc_ldap_server_write_enabled="true"
opencloud_graph_ldap_server_uuid="false"
opencloud_graph_ldap_refint_enabled="true"
opencloud_oc_ldap_insecure="true"
opencloud_proxy_autoprovision_accounts="true"
opencloud_proxy_autoprovision_claim_username="preferred_username"
opencloud_proxy_user_oidc_claim="preferred_username"
opencloud_proxy_user_cs3_claim="username"
opencloud_proxy_oidc_rewrite_wellknown="true"
opencloud_proxy_role_assignment_driver="oidc"
opencloud_graph_assign_default_user_role="false"
opencloud_graph_username_match="none"
opencloud_oc_exclude_run_services="idp"
opencloud_search_extractor_type="tika"
opencloud_search_extractor_tika_tika_url="http://opencloud-tika:9998"
opencloud_frontend_full_text_search_enabled="true"
opencloud_webfinger_web_client_id="web"
opencloud_webfinger_web_scopes="openid profile email roles"
opencloud_webfinger_desktop_client_id="OpenCloudDesktop"
opencloud_webfinger_desktop_scopes="openid profile email roles offline_access"
opencloud_webfinger_android_client_id="OpenCloudAndroid"
opencloud_webfinger_android_scopes="openid profile email roles offline_access"
opencloud_webfinger_ios_client_id="OpenCloudIOS"
opencloud_webfinger_ios_scopes="openid profile email roles offline_access"
opencloud_web_client_id="web"
opencloud_web_scope="openid profile email roles"
opencloud_initial_admin_password="$(openssl rand -hex 24)"

if [[ -n "$existing_opencloud_secret_json" ]]; then
  for pair in \
    "OC_URL:opencloud_oc_url" \
    "OC_OIDC_ISSUER:opencloud_oc_oidc_issuer" \
    "WEB_OPTION_ACCOUNT_EDIT_LINK_HREF:opencloud_web_edit_link" \
    "OC_JWT_SECRET:opencloud_oc_jwt_secret" \
    "COLLABORATION_WOPI_SECRET:opencloud_wopi_secret" \
    "COLLABORATION_WOPI_SRC:opencloud_collaboration_wopi_src" \
    "IDM_ADMIN_PASSWORD:opencloud_idm_admin_password" \
    "OC_LDAP_BIND_PASSWORD:opencloud_ldap_bind_password" \
    "COLLABORA_ADMIN_PASSWORD:opencloud_collabora_admin_password" \
    "COLLABORA_ADMIN_USER:opencloud_collabora_admin_user" \
    "COLLABORA_DOMAIN:opencloud_collabora_domain" \
    "COMPANION_DOMAIN:opencloud_companion_domain" \
    "IDP_DOMAIN:opencloud_idp_domain" \
    "OC_REVA_GATEWAY:opencloud_reva_gateway" \
    "MICRO_REGISTRY_ADDRESS:opencloud_micro_registry_address" \
    "COLLABORATION_APP_NAME:opencloud_collaboration_app_name" \
    "COLLABORATION_APP_PRODUCT:opencloud_collaboration_app_product" \
    "COLLABORATION_APP_ADDR:opencloud_collaboration_app_addr" \
    "COLLABORATION_APP_ICON:opencloud_collaboration_app_icon" \
    "COLLABORATION_APP_INSECURE:opencloud_collaboration_app_insecure" \
    "COLLABORATION_CS3API_DATAGATEWAY_INSECURE:opencloud_collaboration_cs3api_datagateway_insecure" \
    "OC_LDAP_BIND_DN:opencloud_oc_ldap_bind_dn" \
    "OC_LDAP_URI:opencloud_oc_ldap_uri" \
    "OC_LDAP_USER_BASE_DN:opencloud_oc_ldap_user_base_dn" \
    "OC_LDAP_GROUP_BASE_DN:opencloud_oc_ldap_group_base_dn" \
    "OC_LDAP_USER_FILTER:opencloud_oc_ldap_user_filter" \
    "OC_LDAP_USER_SCHEMA_ID:opencloud_oc_ldap_user_schema_id" \
    "OC_LDAP_GROUP_SCHEMA_ID:opencloud_oc_ldap_group_schema_id" \
    "OC_LDAP_DISABLE_USER_MECHANISM:opencloud_oc_ldap_disable_user_mechanism" \
    "OC_LDAP_SERVER_WRITE_ENABLED:opencloud_oc_ldap_server_write_enabled" \
    "GRAPH_LDAP_SERVER_UUID:opencloud_graph_ldap_server_uuid" \
    "GRAPH_LDAP_REFINT_ENABLED:opencloud_graph_ldap_refint_enabled" \
    "OC_LDAP_INSECURE:opencloud_oc_ldap_insecure" \
    "PROXY_AUTOPROVISION_ACCOUNTS:opencloud_proxy_autoprovision_accounts" \
    "PROXY_AUTOPROVISION_CLAIM_USERNAME:opencloud_proxy_autoprovision_claim_username" \
    "PROXY_USER_OIDC_CLAIM:opencloud_proxy_user_oidc_claim" \
    "PROXY_USER_CS3_CLAIM:opencloud_proxy_user_cs3_claim" \
    "PROXY_OIDC_REWRITE_WELLKNOWN:opencloud_proxy_oidc_rewrite_wellknown" \
    "PROXY_ROLE_ASSIGNMENT_DRIVER:opencloud_proxy_role_assignment_driver" \
    "GRAPH_ASSIGN_DEFAULT_USER_ROLE:opencloud_graph_assign_default_user_role" \
    "GRAPH_USERNAME_MATCH:opencloud_graph_username_match" \
    "OC_EXCLUDE_RUN_SERVICES:opencloud_oc_exclude_run_services" \
    "SEARCH_EXTRACTOR_TYPE:opencloud_search_extractor_type" \
    "SEARCH_EXTRACTOR_TIKA_TIKA_URL:opencloud_search_extractor_tika_tika_url" \
    "FRONTEND_FULL_TEXT_SEARCH_ENABLED:opencloud_frontend_full_text_search_enabled" \
    "WEBFINGER_WEB_OIDC_CLIENT_ID:opencloud_webfinger_web_client_id" \
    "WEBFINGER_WEB_OIDC_CLIENT_SCOPES:opencloud_webfinger_web_scopes" \
    "WEBFINGER_DESKTOP_OIDC_CLIENT_ID:opencloud_webfinger_desktop_client_id" \
    "WEBFINGER_DESKTOP_OIDC_CLIENT_SCOPES:opencloud_webfinger_desktop_scopes" \
    "WEBFINGER_ANDROID_OIDC_CLIENT_ID:opencloud_webfinger_android_client_id" \
    "WEBFINGER_ANDROID_OIDC_CLIENT_SCOPES:opencloud_webfinger_android_scopes" \
    "WEBFINGER_IOS_OIDC_CLIENT_ID:opencloud_webfinger_ios_client_id" \
    "WEBFINGER_IOS_OIDC_CLIENT_SCOPES:opencloud_webfinger_ios_scopes" \
    "WEB_OIDC_CLIENT_ID:opencloud_web_client_id" \
    "WEB_OIDC_SCOPE:opencloud_web_scope" \
    "INITIAL_ADMIN_PASSWORD:opencloud_initial_admin_password"
  do
    secret_key="${pair%%:*}"
    var_name="${pair#*:}"
    existing_value="$(jq -r --arg key "$secret_key" '.[$key] // empty' <<<"$existing_opencloud_secret_json")"
    if [[ -n "$existing_value" ]]; then
      printf -v "$var_name" '%s' "$existing_value"
    fi
  done
fi

# These are non-secret integration endpoints. Keep them aligned with the
# current Collabora route even when preserving existing bootstrap secrets.
opencloud_collaboration_app_name="CollaboraOnline"
opencloud_collaboration_app_product="Collabora"
opencloud_collaboration_app_addr="$COLLABORA_HOST"
opencloud_collaboration_app_icon="${COLLABORA_HOST}/favicon.ico"

# Use Authentik global issuer so all OpenCloud providers (web, android,
# desktop, ios) issue tokens with the same issuer URL.
opencloud_oc_oidc_issuer="${AUTHENTIK_HOST}/"

opencloud_secret_file="$(mktemp "${TMPDIR:-/tmp}/opencloud-bootstrap.XXXXXX.json")"
opencloud_rendered_overlay="$(mktemp -d "${TMPDIR:-/tmp}/opencloud-overlay.XXXXXX")"
opencloud_rendered_app_manifest="$(mktemp "${TMPDIR:-/tmp}/opencloud-application.XXXXXX.yaml")"
trap 'rm -f "$opencloud_secret_file" "$opencloud_rendered_app_manifest"; rm -rf "$opencloud_rendered_overlay"' EXIT

jq -n \
  --arg OC_URL "$opencloud_oc_url" \
  --arg OC_OIDC_ISSUER "$opencloud_oc_oidc_issuer" \
  --arg WEB_OPTION_ACCOUNT_EDIT_LINK_HREF "$opencloud_web_edit_link" \
  --arg OC_JWT_SECRET "$opencloud_oc_jwt_secret" \
  --arg COLLABORATION_WOPI_SECRET "$opencloud_wopi_secret" \
  --arg COLLABORATION_WOPI_SRC "$opencloud_collaboration_wopi_src" \
  --arg IDM_ADMIN_PASSWORD "$opencloud_idm_admin_password" \
  --arg OC_LDAP_BIND_PASSWORD "$opencloud_ldap_bind_password" \
  --arg COLLABORA_ADMIN_PASSWORD "$opencloud_collabora_admin_password" \
  --arg COLLABORA_ADMIN_USER "$opencloud_collabora_admin_user" \
  --arg COLLABORA_DOMAIN "$opencloud_collabora_domain" \
  --arg COMPANION_DOMAIN "$opencloud_companion_domain" \
  --arg IDP_DOMAIN "$opencloud_idp_domain" \
  --arg OC_REVA_GATEWAY "$opencloud_reva_gateway" \
  --arg MICRO_REGISTRY_ADDRESS "$opencloud_micro_registry_address" \
  --arg COLLABORATION_APP_NAME "$opencloud_collaboration_app_name" \
  --arg COLLABORATION_APP_PRODUCT "$opencloud_collaboration_app_product" \
  --arg COLLABORATION_APP_ADDR "$opencloud_collaboration_app_addr" \
  --arg COLLABORATION_APP_ICON "$opencloud_collaboration_app_icon" \
  --arg COLLABORATION_APP_INSECURE "$opencloud_collaboration_app_insecure" \
  --arg COLLABORATION_CS3API_DATAGATEWAY_INSECURE "$opencloud_collaboration_cs3api_datagateway_insecure" \
  --arg OC_LDAP_BIND_DN "$opencloud_oc_ldap_bind_dn" \
  --arg OC_LDAP_URI "$opencloud_oc_ldap_uri" \
  --arg OC_LDAP_USER_BASE_DN "$opencloud_oc_ldap_user_base_dn" \
  --arg OC_LDAP_GROUP_BASE_DN "$opencloud_oc_ldap_group_base_dn" \
  --arg OC_LDAP_USER_FILTER "$opencloud_oc_ldap_user_filter" \
  --arg OC_LDAP_USER_SCHEMA_ID "$opencloud_oc_ldap_user_schema_id" \
  --arg OC_LDAP_GROUP_SCHEMA_ID "$opencloud_oc_ldap_group_schema_id" \
  --arg OC_LDAP_DISABLE_USER_MECHANISM "$opencloud_oc_ldap_disable_user_mechanism" \
  --arg OC_LDAP_SERVER_WRITE_ENABLED "$opencloud_oc_ldap_server_write_enabled" \
  --arg GRAPH_LDAP_SERVER_UUID "$opencloud_graph_ldap_server_uuid" \
  --arg GRAPH_LDAP_REFINT_ENABLED "$opencloud_graph_ldap_refint_enabled" \
  --arg OC_LDAP_INSECURE "$opencloud_oc_ldap_insecure" \
  --arg PROXY_AUTOPROVISION_ACCOUNTS "$opencloud_proxy_autoprovision_accounts" \
  --arg PROXY_AUTOPROVISION_CLAIM_USERNAME "$opencloud_proxy_autoprovision_claim_username" \
  --arg PROXY_USER_OIDC_CLAIM "$opencloud_proxy_user_oidc_claim" \
  --arg PROXY_USER_CS3_CLAIM "$opencloud_proxy_user_cs3_claim" \
  --arg PROXY_OIDC_REWRITE_WELLKNOWN "$opencloud_proxy_oidc_rewrite_wellknown" \
  --arg PROXY_ROLE_ASSIGNMENT_DRIVER "$opencloud_proxy_role_assignment_driver" \
  --arg GRAPH_ASSIGN_DEFAULT_USER_ROLE "$opencloud_graph_assign_default_user_role" \
  --arg GRAPH_USERNAME_MATCH "$opencloud_graph_username_match" \
  --arg OC_EXCLUDE_RUN_SERVICES "$opencloud_oc_exclude_run_services" \
  --arg SEARCH_EXTRACTOR_TYPE "$opencloud_search_extractor_type" \
  --arg SEARCH_EXTRACTOR_TIKA_TIKA_URL "$opencloud_search_extractor_tika_tika_url" \
  --arg FRONTEND_FULL_TEXT_SEARCH_ENABLED "$opencloud_frontend_full_text_search_enabled" \
  --arg WEBFINGER_WEB_OIDC_CLIENT_ID "$opencloud_webfinger_web_client_id" \
  --arg WEBFINGER_WEB_OIDC_CLIENT_SCOPES "$opencloud_webfinger_web_scopes" \
  --arg WEBFINGER_DESKTOP_OIDC_CLIENT_ID "$opencloud_webfinger_desktop_client_id" \
  --arg WEBFINGER_DESKTOP_OIDC_CLIENT_SCOPES "$opencloud_webfinger_desktop_scopes" \
  --arg WEBFINGER_ANDROID_OIDC_CLIENT_ID "$opencloud_webfinger_android_client_id" \
  --arg WEBFINGER_ANDROID_OIDC_CLIENT_SCOPES "$opencloud_webfinger_android_scopes" \
  --arg WEBFINGER_IOS_OIDC_CLIENT_ID "$opencloud_webfinger_ios_client_id" \
  --arg WEBFINGER_IOS_OIDC_CLIENT_SCOPES "$opencloud_webfinger_ios_scopes" \
  --arg WEB_OIDC_CLIENT_ID "$opencloud_web_client_id" \
  --arg WEB_OIDC_SCOPE "$opencloud_web_scope" \
  --arg INITIAL_ADMIN_PASSWORD "$opencloud_initial_admin_password" \
  '{
    OC_URL: $OC_URL,
    OC_OIDC_ISSUER: $OC_OIDC_ISSUER,
    WEB_OPTION_ACCOUNT_EDIT_LINK_HREF: $WEB_OPTION_ACCOUNT_EDIT_LINK_HREF,
    OC_JWT_SECRET: $OC_JWT_SECRET,
    COLLABORATION_WOPI_SECRET: $COLLABORATION_WOPI_SECRET,
    COLLABORATION_WOPI_SRC: $COLLABORATION_WOPI_SRC,
    IDM_ADMIN_PASSWORD: $IDM_ADMIN_PASSWORD,
    OC_LDAP_BIND_PASSWORD: $OC_LDAP_BIND_PASSWORD,
    COLLABORA_ADMIN_PASSWORD: $COLLABORA_ADMIN_PASSWORD,
    COLLABORA_ADMIN_USER: $COLLABORA_ADMIN_USER,
    COLLABORA_DOMAIN: $COLLABORA_DOMAIN,
    COMPANION_DOMAIN: $COMPANION_DOMAIN,
    IDP_DOMAIN: $IDP_DOMAIN,
    OC_REVA_GATEWAY: $OC_REVA_GATEWAY,
    MICRO_REGISTRY_ADDRESS: $MICRO_REGISTRY_ADDRESS,
    COLLABORATION_APP_NAME: $COLLABORATION_APP_NAME,
    COLLABORATION_APP_PRODUCT: $COLLABORATION_APP_PRODUCT,
    COLLABORATION_APP_ADDR: $COLLABORATION_APP_ADDR,
    COLLABORATION_APP_ICON: $COLLABORATION_APP_ICON,
    COLLABORATION_APP_INSECURE: $COLLABORATION_APP_INSECURE,
    COLLABORATION_CS3API_DATAGATEWAY_INSECURE: $COLLABORATION_CS3API_DATAGATEWAY_INSECURE,
    OC_LDAP_BIND_DN: $OC_LDAP_BIND_DN,
    OC_LDAP_URI: $OC_LDAP_URI,
    OC_LDAP_USER_BASE_DN: $OC_LDAP_USER_BASE_DN,
    OC_LDAP_GROUP_BASE_DN: $OC_LDAP_GROUP_BASE_DN,
    OC_LDAP_USER_FILTER: $OC_LDAP_USER_FILTER,
    OC_LDAP_USER_SCHEMA_ID: $OC_LDAP_USER_SCHEMA_ID,
    OC_LDAP_GROUP_SCHEMA_ID: $OC_LDAP_GROUP_SCHEMA_ID,
    OC_LDAP_DISABLE_USER_MECHANISM: $OC_LDAP_DISABLE_USER_MECHANISM,
    OC_LDAP_SERVER_WRITE_ENABLED: $OC_LDAP_SERVER_WRITE_ENABLED,
    GRAPH_LDAP_SERVER_UUID: $GRAPH_LDAP_SERVER_UUID,
    GRAPH_LDAP_REFINT_ENABLED: $GRAPH_LDAP_REFINT_ENABLED,
    OC_LDAP_INSECURE: $OC_LDAP_INSECURE,
    PROXY_AUTOPROVISION_ACCOUNTS: $PROXY_AUTOPROVISION_ACCOUNTS,
    PROXY_AUTOPROVISION_CLAIM_USERNAME: $PROXY_AUTOPROVISION_CLAIM_USERNAME,
    PROXY_USER_OIDC_CLAIM: $PROXY_USER_OIDC_CLAIM,
    PROXY_USER_CS3_CLAIM: $PROXY_USER_CS3_CLAIM,
    PROXY_OIDC_REWRITE_WELLKNOWN: $PROXY_OIDC_REWRITE_WELLKNOWN,
    PROXY_ROLE_ASSIGNMENT_DRIVER: $PROXY_ROLE_ASSIGNMENT_DRIVER,
    GRAPH_ASSIGN_DEFAULT_USER_ROLE: $GRAPH_ASSIGN_DEFAULT_USER_ROLE,
    GRAPH_USERNAME_MATCH: $GRAPH_USERNAME_MATCH,
    OC_EXCLUDE_RUN_SERVICES: $OC_EXCLUDE_RUN_SERVICES,
    SEARCH_EXTRACTOR_TYPE: $SEARCH_EXTRACTOR_TYPE,
    SEARCH_EXTRACTOR_TIKA_TIKA_URL: $SEARCH_EXTRACTOR_TIKA_TIKA_URL,
    FRONTEND_FULL_TEXT_SEARCH_ENABLED: $FRONTEND_FULL_TEXT_SEARCH_ENABLED,
    WEBFINGER_WEB_OIDC_CLIENT_ID: $WEBFINGER_WEB_OIDC_CLIENT_ID,
    WEBFINGER_WEB_OIDC_CLIENT_SCOPES: $WEBFINGER_WEB_OIDC_CLIENT_SCOPES,
    WEBFINGER_DESKTOP_OIDC_CLIENT_ID: $WEBFINGER_DESKTOP_OIDC_CLIENT_ID,
    WEBFINGER_DESKTOP_OIDC_CLIENT_SCOPES: $WEBFINGER_DESKTOP_OIDC_CLIENT_SCOPES,
    WEBFINGER_ANDROID_OIDC_CLIENT_ID: $WEBFINGER_ANDROID_OIDC_CLIENT_ID,
    WEBFINGER_ANDROID_OIDC_CLIENT_SCOPES: $WEBFINGER_ANDROID_OIDC_CLIENT_SCOPES,
    WEBFINGER_IOS_OIDC_CLIENT_ID: $WEBFINGER_IOS_OIDC_CLIENT_ID,
    WEBFINGER_IOS_OIDC_CLIENT_SCOPES: $WEBFINGER_IOS_OIDC_CLIENT_SCOPES,
    WEB_OIDC_CLIENT_ID: $WEB_OIDC_CLIENT_ID,
    WEB_OIDC_SCOPE: $WEB_OIDC_SCOPE,
    INITIAL_ADMIN_PASSWORD: $INITIAL_ADMIN_PASSWORD
  }' >"$opencloud_secret_file"

log "Writing OpenCloud bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "opencloud" \
  --json-file "$opencloud_secret_file" \
  --required-keys "OC_URL,OC_OIDC_ISSUER,WEB_OPTION_ACCOUNT_EDIT_LINK_HREF,OC_JWT_SECRET,COLLABORATION_WOPI_SECRET,COLLABORATION_WOPI_SRC,IDM_ADMIN_PASSWORD,OC_LDAP_BIND_PASSWORD,COLLABORA_ADMIN_PASSWORD,COLLABORA_ADMIN_USER,COLLABORA_DOMAIN,COMPANION_DOMAIN,IDP_DOMAIN,OC_REVA_GATEWAY,MICRO_REGISTRY_ADDRESS,COLLABORATION_APP_NAME,COLLABORATION_APP_PRODUCT,COLLABORATION_APP_ADDR,COLLABORATION_APP_ICON,COLLABORATION_APP_INSECURE,COLLABORATION_CS3API_DATAGATEWAY_INSECURE,OC_LDAP_BIND_DN,OC_LDAP_URI,OC_LDAP_USER_BASE_DN,OC_LDAP_GROUP_BASE_DN,OC_LDAP_USER_FILTER,OC_LDAP_USER_SCHEMA_ID,OC_LDAP_GROUP_SCHEMA_ID,OC_LDAP_DISABLE_USER_MECHANISM,OC_LDAP_SERVER_WRITE_ENABLED,GRAPH_LDAP_SERVER_UUID,GRAPH_LDAP_REFINT_ENABLED,OC_LDAP_INSECURE,PROXY_AUTOPROVISION_ACCOUNTS,PROXY_AUTOPROVISION_CLAIM_USERNAME,PROXY_USER_OIDC_CLAIM,PROXY_USER_CS3_CLAIM,PROXY_OIDC_REWRITE_WELLKNOWN,PROXY_ROLE_ASSIGNMENT_DRIVER,GRAPH_ASSIGN_DEFAULT_USER_ROLE,GRAPH_USERNAME_MATCH,OC_EXCLUDE_RUN_SERVICES,SEARCH_EXTRACTOR_TYPE,SEARCH_EXTRACTOR_TIKA_TIKA_URL,FRONTEND_FULL_TEXT_SEARCH_ENABLED,WEBFINGER_WEB_OIDC_CLIENT_ID,WEBFINGER_WEB_OIDC_CLIENT_SCOPES,WEBFINGER_DESKTOP_OIDC_CLIENT_ID,WEBFINGER_DESKTOP_OIDC_CLIENT_SCOPES,WEBFINGER_ANDROID_OIDC_CLIENT_ID,WEBFINGER_ANDROID_OIDC_CLIENT_SCOPES,WEBFINGER_IOS_OIDC_CLIENT_ID,WEBFINGER_IOS_OIDC_CLIENT_SCOPES,WEB_OIDC_CLIENT_ID,WEB_OIDC_SCOPE,INITIAL_ADMIN_PASSWORD"

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

roles_mapping_id="$(upsert_scope_mapping \
  "OpenCloud roles" \
  "roles" \
  "Return OpenCloud identity and role claims" \
  'roles = ["opencloudUser"]
if ak_is_group_member(request.user, name="admins"):
    roles = ["opencloudAdmin", "opencloudUser"]
return {
    "sub": request.user.uid,
    "username": request.user.username,
    "preferred_username": request.user.username,
    "name": request.user.name or request.user.username,
    "email": request.user.email,
    "roles": roles,
}' )"
[[ -n "$roles_mapping_id" ]] || fail "Could not create the OpenCloud roles mapping"

offline_access_mapping_id="$(upsert_scope_mapping \
  "OpenCloud offline_access" \
  "offline_access" \
  "Enable refresh tokens for OpenCloud clients" \
  'return {}' )"
[[ -n "$offline_access_mapping_id" ]] || fail "Could not create the OpenCloud offline_access mapping"

opencloud_property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    --arg roles "$roles_mapping_id" \
    --arg offline_access "$offline_access_mapping_id" \
    '[$openid, $email, $profile, $roles, $offline_access]'
)"

opencloud_web_provider_payload="$(
  jq -n \
    --arg name "OpenCloud Web" \
    --arg slug "opencloud-web" \
    --arg client_id "web" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    --arg roles "$roles_mapping_id" \
    --arg redirect_1 "${OPENCLOUD_HOST}/" \
    --arg redirect_2 "${OPENCLOUD_HOST}/oidc-callback.html" \
    --arg redirect_3 "${OPENCLOUD_HOST}/oidc-silent-redirect.html" \
    '{
      name: $name,
      slug: $slug,
      client_id: $client_id,
      client_type: "public",
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      issuer_mode: "global",
      include_claims_in_id_token: true,
      property_mappings: $property_mappings,
      redirect_uris: [
        { matching_mode: "strict", url: $redirect_1 },
        { matching_mode: "strict", url: $redirect_2 },
        { matching_mode: "strict", url: $redirect_3 }
      ]
    }' \
    --argjson property_mappings "$opencloud_property_mapping_ids_json"
)"
opencloud_web_provider_pk="$(create_or_update_provider "OpenCloud Web" "opencloud-web" "$opencloud_web_provider_payload")"
[[ -n "$opencloud_web_provider_pk" ]] || fail "Authentik did not return a provider ID for OpenCloud Web"

opencloud_web_application_payload="$(
  jq -n \
    --arg name "OpenCloud" \
    --arg slug "opencloud" \
    --arg launch_url "$OPENCLOUD_HOST" \
    --arg provider_pk "$opencloud_web_provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
opencloud_web_application_pk="$(create_or_update_application "opencloud" "$opencloud_web_application_payload")"
[[ -n "$opencloud_web_application_pk" ]] || fail "Authentik did not return an application ID for OpenCloud"

for provider_name in "OpenCloud Desktop" "OpenCloud Android" "OpenCloud iOS" "Cyberduck"; do
  case "$provider_name" in
    "OpenCloud Desktop")
      client_id="OpenCloudDesktop"
      slug="opencloud-desktop"
      redirect_uris='[
        { "matching_mode": "strict", "url": "http://127.0.0.1" },
        { "matching_mode": "strict", "url": "http://localhost" }
      ]'
      ;;
    "OpenCloud Android")
      client_id="OpenCloudAndroid"
      slug="opencloud-android"
      redirect_uris='[
        { "matching_mode": "strict", "url": "oc://android.opencloud.eu" }
      ]'
      ;;
    "OpenCloud iOS")
      client_id="OpenCloudIOS"
      slug="opencloud-ios"
      redirect_uris='[
        { "matching_mode": "strict", "url": "oc://ios.opencloud.eu" }
      ]'
      ;;
    "Cyberduck")
      client_id="Cyberduck"
      slug="opencloud-cyberduck"
      redirect_uris='[
        { "matching_mode": "strict", "url": "x-cyberduck-action:oauth" },
        { "matching_mode": "strict", "url": "x-mountainduck-action:oauth" }
      ]'
      ;;
  esac

  provider_payload="$(
    jq -n \
      --arg name "$provider_name" \
      --arg slug "$slug" \
      --arg client_id "$client_id" \
      --arg authorization_flow "$authorization_flow_id" \
      --arg invalidation_flow "$invalidation_flow_id" \
      --arg signing_key "$signing_key_id" \
      --arg openid "$openid_mapping_id" \
      --arg email "$email_mapping_id" \
      --arg profile "$profile_mapping_id" \
      --arg roles "$roles_mapping_id" \
      --argjson redirect_uris "$redirect_uris" \
      '{
        name: $name,
        slug: $slug,
        client_id: $client_id,
        client_type: "public",
        authorization_flow: $authorization_flow,
        invalidation_flow: $invalidation_flow,
        signing_key: $signing_key,
        issuer_mode: "global",
        include_claims_in_id_token: true,
        property_mappings: $property_mappings,
        redirect_uris: $redirect_uris
      }' \
      --argjson property_mappings "$opencloud_property_mapping_ids_json"
  )"
  provider_pk="$(create_or_update_provider "$provider_name" "$slug" "$provider_payload")"
  [[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for ${provider_name}"

  application_payload="$(
    jq -n \
      --arg name "$provider_name" \
      --arg slug "$slug" \
      --arg provider_pk "$provider_pk" \
      '{
        name: $name,
        slug: $slug,
        provider: ($provider_pk | tonumber)
      }'
  )"
  application_pk="$(create_or_update_application "$slug" "$application_payload")"
  [[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for ${provider_name}"
done

log "Rendering OpenCloud GitOps overlay"
render_opencloud_overlay "$WORKSPACE_ROOT/gitops/platform-apps/opencloud" "$opencloud_rendered_overlay" "$public_zone_name"

log "Applying OpenCloud GitOps overlay"
kubectl apply -k "$opencloud_rendered_overlay"

log "Applying OpenCloud Argo CD application"
sed \
  -e "s|__REPO_URL__|${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}|g" \
  -e "s|__TARGET_REVISION__|${TWINBOX_GIT_TARGET_REVISION:-main}|g" \
  "$WORKSPACE_ROOT/gitops/apps/opencloud.yaml" >"$opencloud_rendered_app_manifest"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$opencloud_rendered_app_manifest" \
  --application "opencloud" \
  --destination-namespace "opencloud"

wait_for_resources_ready "opencloud" "externalsecret" "Ready" "OpenCloud ExternalSecret"
wait_for_statefulset_ready "opencloud" "opencloud-ldap" "OpenCloud LDAP"
wait_for_opencloud_ldap_directory
wait_for_deployment_rollout "opencloud" "opencloud" "OpenCloud core"
wait_for_deployment_rollout "opencloud" "opencloud-collaboration" "OpenCloud collaboration"
wait_for_deployment_rollout "opencloud" "opencloud-collabora" "OpenCloud Collabora"
wait_for_deployment_rollout "opencloud" "opencloud-radicale" "OpenCloud Radicale"
wait_for_deployment_rollout "opencloud" "opencloud-tika" "OpenCloud Tika"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg public_url "$OPENCLOUD_HOST" \
    --arg collabora_url "$COLLABORA_HOST" \
    --arg wopiserver_url "$WOPISERVER_HOST" \
    '{
      public_url: $public_url,
      collabora_url: $collabora_url,
      wopiserver_url: $wopiserver_url
    }' >"$STEP_RESULT_FILE"
fi

log "OpenCloud installation completed"
