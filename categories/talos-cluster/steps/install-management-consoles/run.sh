#!/usr/bin/env bash
set -Eeuo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

CURRENT_APP_NAME=""
CURRENT_APP_SLUG=""
CURRENT_RESOURCE_TYPE=""
CURRENT_OPERATION=""
CURRENT_ENDPOINT=""
AUTHENTIK_RESOURCE_ID=""
IN_FAIL="false"

fail() {
  fail_with_context "$@"
}

fail_with_context() {
  local message="$1"
  local context=""

  IN_FAIL="true"
  trap - ERR

  if [[ -n "$CURRENT_APP_NAME" ]]; then
    context="${context} app=${CURRENT_APP_NAME}"
  fi
  if [[ -n "$CURRENT_APP_SLUG" ]]; then
    context="${context} slug=${CURRENT_APP_SLUG}"
  fi
  if [[ -n "$CURRENT_RESOURCE_TYPE" ]]; then
    context="${context} resource=${CURRENT_RESOURCE_TYPE}"
  fi
  if [[ -n "$CURRENT_OPERATION" ]]; then
    context="${context} operation=${CURRENT_OPERATION}"
  fi
  if [[ -n "$CURRENT_ENDPOINT" ]]; then
    context="${context} endpoint=${CURRENT_ENDPOINT}"
  fi

  if [[ -n "$context" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${message} (${context# })" >&2
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${message}" >&2
  fi
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

log_step() {
  log "$*"
}

log_app_start() {
  log "Provisioning management console: $1"
}

log_app_done() {
  log "Provisioned management console: $1 (provider=$2, application=$3)"
}

set_context() {
  CURRENT_APP_NAME="${1:-}"
  CURRENT_APP_SLUG="${2:-}"
  CURRENT_RESOURCE_TYPE="${3:-}"
  CURRENT_OPERATION="${4:-}"
  CURRENT_ENDPOINT="${5:-}"
}

clear_context() {
  set_context "" "" "" "" ""
}

on_unexpected_error() {
  local status="$1"
  local line="$2"

  [[ "$IN_FAIL" == "true" ]] && exit "$status"
  fail_with_context "Unexpected command failure at line ${line} with exit code ${status}"
}

trap 'on_unexpected_error "$?" "$LINENO"' ERR

wait_for_deployment_rollout() {
  local deployment="$1"
  local label="${2:-$deployment}"
  local attempts=120
  local attempt=1
  local status_json=""
  local desired_replicas=""
  local updated_replicas=""
  local ready_replicas=""
  local available_replicas=""

  while true; do
    if status_json="$(kubectl -n authentik get deployment "$deployment" -o json 2>/dev/null)"; then
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

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

wait_for_deployment_rollout "authentik-server" "Authentik server"
wait_for_deployment_rollout "authentik-worker" "Authentik worker"

authentik_ensure_token
authentik_setup_forward

wait_for_authentik_api_ready() {
  local attempt=1
  local attempts=60
  local response_file status body
  local auth_headers=(-H "Accept: application/json")

  if [[ "${AUTHENTIK_USE_COOKIE:-false}" == "true" ]]; then
    auth_headers+=(-H "Cookie: ${AUTHENTIK_TOKEN}")
  else
    auth_headers+=(-H "Authorization: Bearer ${AUTHENTIK_TOKEN}")
  fi

  while [[ "$attempt" -le "$attempts" ]]; do
    response_file="$(mktemp)"
    status="$(
      curl -sS \
        --connect-timeout 10 \
        --max-time 30 \
        "${auth_headers[@]}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${AUTHENTIK_API_BASE}/flows/instances/?page_size=1"
    )" || status="000"

    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"

    if [[ "$status" =~ ^2 ]]; then
      return 0
    fi

    log "Waiting for Authentik API readiness (${attempt}/${attempts}): HTTP ${status}"

    if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]] && ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
      log "Authentik port-forward died while waiting for API readiness; re-establishing"
      authentik_setup_forward
    fi

    sleep 2
    attempt=$((attempt + 1))
  done

  fail "Authentik API did not become ready after ${attempts} attempts"
}

wait_for_authentik_api_ready

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"

for attempt in $(seq 1 120); do
  if kubectl -n traefik get ingressroute/traefik-dashboard >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/longhorn >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/proxmox >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/webwizard >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/seaweedfs >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/seaweedfs-admin >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: management console ingress routes did not appear in time" >&2
    exit 1
  fi
  sleep 5
done

find_proxy_provider_pk_by_name() {
  local provider_name="$1"
  local application_slug="${2:-}"
  local response

  authentik_get_json_context response "/providers/proxy/?page_size=100" "$provider_name" "$application_slug" "proxy provider" "lookup" "true" \
    || return 0
  jq -r \
    --arg provider_name "$provider_name" \
    'limit(1; .results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // .uuid // empty)' <<<"$response"
}

find_application_json_by_slug() {
  local application_slug="$1"
  local application_name="${2:-$CURRENT_APP_NAME}"
  local response

  authentik_get_json_context response "/core/applications/${application_slug}/" "$application_name" "$application_slug" "application" "lookup" "true" \
    || return 0
  printf '%s' "$response"
}

find_policy_binding_pk() {
  local target_uuid="$1"
  local group_id="$2"
  local response

  authentik_get_json_context response "/policies/bindings/?page_size=200" "$CURRENT_APP_NAME" "$CURRENT_APP_SLUG" "policy binding" "lookup" "true" \
    || return 0
  jq -r \
    --arg target_uuid "$target_uuid" \
    --arg group_id "$group_id" \
    'limit(1; .results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // .uuid // empty)' <<<"$response"
}

extract_authentik_identifier() {
  local payload="${1:-}"

  [[ -n "$payload" ]] || return 0
  jq -er '.pk // .id // .uuid // empty' <<<"$payload" 2>/dev/null || true
}

safe_authentik_error_summary() {
  local body="${1:-}"

  if [[ -z "$body" ]]; then
    printf 'empty response body'
    return 0
  fi

  if jq -e . >/dev/null 2>&1 <<<"$body"; then
    jq -cr '
      if type == "object" then
        {
          detail: (.detail // empty),
          error: (.error // empty),
          non_field_errors: (.non_field_errors // empty),
          fields: (keys_unsorted | map(select(. != "token" and . != "key" and . != "password" and . != "secret")))
        }
        | with_entries(select(.value != null and .value != "" and .value != []))
      else
        {response_type: type}
      end
    ' <<<"$body"
    return 0
  fi

  printf '%s' "$body" | tr '\n' ' ' | cut -c1-240
}

authentik_request_context() {
  local output_var="$1"
  local method="$2"
  local path="$3"
  local data="${4:-}"
  local app_name="$5"
  local app_slug="$6"
  local resource_type="$7"
  local operation="$8"
  local allow_failure="${9:-false}"
  local response_file status body summary curl_rc
  local attempt=1
  local max_attempts=5
  local retry_delay=1
  local auth_headers=(-H "Accept: application/json")

  set_context "$app_name" "$app_slug" "$resource_type" "$operation" "$path"

  [[ -n "${AUTHENTIK_API_BASE:-}" ]] || fail "AUTHENTIK_API_BASE is not set"
  [[ -n "${AUTHENTIK_TOKEN:-}" ]] || fail "AUTHENTIK_TOKEN is not set"

  if [[ "${AUTHENTIK_USE_COOKIE:-false}" == "true" ]]; then
    auth_headers+=(-H "Cookie: ${AUTHENTIK_TOKEN}")
  else
    auth_headers+=(-H "Authorization: Bearer ${AUTHENTIK_TOKEN}")
  fi

  while true; do
    response_file="$(mktemp)"
    set +e
    if [[ -n "$data" ]]; then
      status="$(
        curl -sS \
          --connect-timeout 10 \
          --max-time 60 \
          -X "$method" \
          "${auth_headers[@]}" \
          -H "Content-Type: application/json" \
          --data-binary "$data" \
          -o "$response_file" \
          -w '%{http_code}' \
          "${AUTHENTIK_API_BASE}${path}"
      )"
      curl_rc="$?"
    else
      status="$(
        curl -sS \
          --connect-timeout 10 \
          --max-time 60 \
          -X "$method" \
          "${auth_headers[@]}" \
          -o "$response_file" \
          -w '%{http_code}' \
          "${AUTHENTIK_API_BASE}${path}"
      )"
      curl_rc="$?"
    fi
    set -e

    if [[ "$curl_rc" -ne 0 ]]; then
      status="000"
    fi

    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"

    if [[ "$status" =~ ^2 ]]; then
      if [[ -n "$body" ]] && ! jq -e . >/dev/null 2>&1 <<<"$body"; then
        fail "Authentik API returned invalid JSON with HTTP ${status}"
      fi
      printf -v "$output_var" '%s' "$body"
      return 0
    fi

    if [[ "$status" == "000" || "$status" =~ ^5 ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]] && ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
          log "Authentik port-forward died while calling ${method} ${path}; re-establishing"
          authentik_setup_forward
        fi
        summary="$(safe_authentik_error_summary "$body")"
        log "Retrying Authentik API ${method} ${path} after transient HTTP ${status} curl_rc=${curl_rc}: ${summary}"
        sleep "$retry_delay"
        attempt=$((attempt + 1))
        retry_delay=$((retry_delay * 2))
        continue
      fi
    fi

    summary="$(safe_authentik_error_summary "$body")"
    log "Authentik API ${method} ${path} failed with HTTP ${status} curl_rc=${curl_rc}: ${summary}"
    printf -v "$output_var" '%s' "$body"

    if [[ "$allow_failure" == "true" ]]; then
      return 1
    fi

    fail "Authentik API ${method} ${path} failed with HTTP ${status} curl_rc=${curl_rc}: ${summary}"
  done
}

authentik_get_json_context() {
  local output_var="$1"
  local path="$2"
  local app_name="$3"
  local app_slug="$4"
  local resource_type="$5"
  local operation="$6"
  local allow_failure="${7:-false}"

  authentik_request_context "$output_var" GET "$path" "" "$app_name" "$app_slug" "$resource_type" "$operation" "$allow_failure"
}

authentik_write_or_fail_context() {
  local output_var="$1"
  local method="$2"
  local path="$3"
  local payload="$4"
  local app_name="$5"
  local app_slug="$6"
  local resource_type="$7"
  local operation="$8"
  local allow_failure="${9:-false}"

  authentik_request_context "$output_var" "$method" "$path" "$payload" "$app_name" "$app_slug" "$resource_type" "$operation" "$allow_failure"
}

create_or_update_proxy_provider() {
  local provider_name="$1"
  local application_slug="$2"
  local provider_payload="$3"
  local existing_pk response created_pk

  existing_pk="$(find_proxy_provider_pk_by_name "$provider_name" "$application_slug")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik proxy provider for ${provider_name} (provider=${existing_pk})"
    authentik_write_or_fail_context response PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" "$provider_name" "$application_slug" "proxy provider" "update"
    AUTHENTIK_RESOURCE_ID="$existing_pk"
    return 0
  fi

  log "Creating Authentik proxy provider for ${provider_name}"
  if authentik_write_or_fail_context response POST "/providers/proxy/" "$provider_payload" "$provider_name" "$application_slug" "proxy provider" "create" "true"; then
    created_pk="$(extract_authentik_identifier "$response")"
    if [[ -n "$created_pk" ]]; then
      AUTHENTIK_RESOURCE_ID="$created_pk"
      return 0
    fi
    log "Authentik proxy provider create for ${provider_name} returned no identifier; checking by name"
  else
    log "Recovering Authentik proxy provider for ${provider_name} after create failure by looking it up"
  fi

  existing_pk="$(find_proxy_provider_pk_by_name "$provider_name" "$application_slug")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose a proxy provider ID for ${provider_name}"
  log "Recovered Authentik proxy provider for ${provider_name} (provider=${existing_pk})"
  authentik_write_or_fail_context response PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" "$provider_name" "$application_slug" "proxy provider" "reconcile"
  AUTHENTIK_RESOURCE_ID="$existing_pk"
}

create_or_update_application() {
  local application_slug="$1"
  local application_name="$2"
  local application_payload="$3"
  local existing_json existing_pk response created_pk

  existing_json="$(find_application_json_by_slug "$application_slug" "$application_name" || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik application for ${application_name} (application=${existing_pk})"
    authentik_write_or_fail_context response PATCH "/core/applications/${application_slug}/" "$application_payload" "$application_name" "$application_slug" "application" "update"
    AUTHENTIK_RESOURCE_ID="$existing_pk"
    return 0
  fi

  log "Creating Authentik application for ${application_name}"
  if authentik_write_or_fail_context response POST "/core/applications/" "$application_payload" "$application_name" "$application_slug" "application" "create" "true"; then
    created_pk="$(extract_authentik_identifier "$response")"
    if [[ -n "$created_pk" ]]; then
      AUTHENTIK_RESOURCE_ID="$created_pk"
      return 0
    fi
    log "Authentik application create for ${application_name} returned no identifier; checking by slug"
  else
    log "Recovering Authentik application for ${application_name} after create failure by looking it up"
  fi

  existing_json="$(find_application_json_by_slug "$application_slug" "$application_name" || true)"
  existing_pk="$(extract_authentik_identifier "$existing_json")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose an application ID for ${application_name}"

  log "Recovered Authentik application for ${application_name} (application=${existing_pk})"
  authentik_write_or_fail_context response PATCH "/core/applications/${application_slug}/" "$application_payload" "$application_name" "$application_slug" "application" "reconcile"
  AUTHENTIK_RESOURCE_ID="$existing_pk"
}

ensure_group_binding() {
  local target_uuid="$1"
  local group_id="$2"
  local binding_payload existing_pk response

  binding_payload="$(
    jq -n \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
  )"

  existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"
  if [[ -n "$existing_pk" ]]; then
    log "Updating Authentik admins binding for ${CURRENT_APP_NAME} (binding=${existing_pk})"
    authentik_write_or_fail_context response PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" "$CURRENT_APP_NAME" "$CURRENT_APP_SLUG" "policy binding" "update"
    return 0
  fi

  log "Creating Authentik admins binding for ${CURRENT_APP_NAME}"
  if authentik_write_or_fail_context response POST "/policies/bindings/" "$binding_payload" "$CURRENT_APP_NAME" "$CURRENT_APP_SLUG" "policy binding" "create" "true"; then
    return 0
  fi

  existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not create or expose the admins policy binding"
  log "Recovered Authentik admins binding for ${CURRENT_APP_NAME} after create failure (binding=${existing_pk})"
}

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

management_apps_json="$(
  jq -nc \
    --arg public_zone_name "$public_zone_name" \
    '[
      {
        key: "traefik_dashboard",
        name: "Traefik Dashboard",
        slug: "traefik-dashboard",
        external_host: "https://traefik.\($public_zone_name)",
        launch_url: "https://traefik.\($public_zone_name)/dashboard/"
      },
      {
        key: "longhorn",
        name: "Longhorn",
        slug: "longhorn",
        external_host: "https://longhorn.\($public_zone_name)",
        launch_url: "https://longhorn.\($public_zone_name)"
      },
      {
        key: "hubble",
        name: "Hubble",
        slug: "hubble",
        external_host: "https://hubble.\($public_zone_name)",
        launch_url: "https://hubble.\($public_zone_name)"
      },
      {
        key: "proxmox",
        name: "Proxmox",
        slug: "proxmox",
        external_host: "https://proxmox.\($public_zone_name)",
        launch_url: "https://proxmox.\($public_zone_name)"
      },
      {
        key: "webwizard",
        name: "Web Wizard",
        slug: "webwizard",
        external_host: "https://webwizard.\($public_zone_name)",
        launch_url: "https://webwizard.\($public_zone_name)"
      },
      {
        key: "seaweedfs",
        name: "SeaweedFS",
        slug: "seaweedfs",
        external_host: "https://seaweedfs.\($public_zone_name)",
        launch_url: "https://seaweedfs.\($public_zone_name)"
      },
      {
        key: "seaweedfs_admin",
        name: "SeaweedFS Admin",
        slug: "seaweedfs-admin",
        external_host: "https://seaweedfs-admin.\($public_zone_name)",
        launch_url: "https://seaweedfs-admin.\($public_zone_name)"
      }
    ]'
)"

log_step "Provisioning Authentik proxy applications for Traefik, Longhorn, Hubble, Proxmox, Web Wizard, and SeaweedFS"

provider_ids_json='{}'
application_ids_json='{}'
while IFS= read -r app_json; do
  app_key="$(jq -r '.key' <<<"$app_json")"
  app_name="$(jq -r '.name' <<<"$app_json")"
  app_slug="$(jq -r '.slug' <<<"$app_json")"
  app_external_host="$(jq -r '.external_host' <<<"$app_json")"
  app_launch_url="$(jq -r '.launch_url' <<<"$app_json")"
  set_context "$app_name" "$app_slug" "management console" "provision" ""
  log_app_start "$app_name"

  provider_payload="$(
    jq -n \
      --arg name "$app_name" \
      --arg external_host "$app_external_host" \
      --arg authorization_flow "$authorization_flow_id" \
      --arg invalidation_flow "$invalidation_flow_id" \
      '{
        name: $name,
        external_host: $external_host,
        authorization_flow: $authorization_flow,
        invalidation_flow: $invalidation_flow,
        mode: "forward_single"
      }'
  )"
  AUTHENTIK_RESOURCE_ID=""
  create_or_update_proxy_provider "$app_name" "$app_slug" "$provider_payload"
  provider_pk="$AUTHENTIK_RESOURCE_ID"
  [[ -n "$provider_pk" ]] || fail "Authentik did not return a proxy provider ID for ${app_name}"

  application_payload="$(
    jq -n \
      --arg name "$app_name" \
      --arg slug "$app_slug" \
      --arg launch_url "$app_launch_url" \
      --arg provider_pk "$provider_pk" \
      '{
        name: $name,
        slug: $slug,
        meta_launch_url: $launch_url,
        provider: ($provider_pk | tonumber)
      }'
  )"
  AUTHENTIK_RESOURCE_ID=""
  create_or_update_application "$app_slug" "$app_name" "$application_payload"
  application_pk="$AUTHENTIK_RESOURCE_ID"
  [[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for ${app_name}"

  authentik_get_json_context application_json "/core/applications/${app_slug}/" "$app_name" "$app_slug" "application" "verify"
  application_uuid="$(extract_authentik_identifier "$application_json")"
  [[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for ${app_name}"
  ensure_group_binding "$application_uuid" "$admins_group_id"

  provider_ids_json="$(jq -c --arg app_key "$app_key" --arg provider_pk "$provider_pk" '. + {($app_key): $provider_pk}' <<<"$provider_ids_json")"
  application_ids_json="$(jq -c --arg app_key "$app_key" --arg application_pk "$application_pk" '. + {($app_key): $application_pk}' <<<"$application_ids_json")"
  log_app_done "$app_name" "$provider_pk" "$application_pk"
done < <(jq -c '.[]' <<<"$management_apps_json")
clear_context

traefik_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.traefik_dashboard')"
longhorn_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.longhorn')"
hubble_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.hubble')"
proxmox_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.proxmox')"
webwizard_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.webwizard')"
seaweedfs_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.seaweedfs')"
seaweedfs_admin_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.seaweedfs_admin')"

[[ "$traefik_provider_id" != "null" && -n "$traefik_provider_id" ]] || fail "Could not determine Traefik provider ID"
[[ "$longhorn_provider_id" != "null" && -n "$longhorn_provider_id" ]] || fail "Could not determine Longhorn provider ID"
[[ "$hubble_provider_id" != "null" && -n "$hubble_provider_id" ]] || fail "Could not determine Hubble provider ID"
[[ "$proxmox_provider_id" != "null" && -n "$proxmox_provider_id" ]] || fail "Could not determine Proxmox provider ID"
[[ "$webwizard_provider_id" != "null" && -n "$webwizard_provider_id" ]] || fail "Could not determine Web Wizard provider ID"
[[ "$seaweedfs_provider_id" != "null" && -n "$seaweedfs_provider_id" ]] || fail "Could not determine SeaweedFS provider ID"
[[ "$seaweedfs_admin_provider_id" != "null" && -n "$seaweedfs_admin_provider_id" ]] || fail "Could not determine SeaweedFS admin provider ID"

set_context "authentik Embedded Outpost" "" "outpost" "lookup" "/outposts/instances/?page_size=100"
authentik_get_json_context outpost_json "/outposts/instances/?page_size=100" "authentik Embedded Outpost" "" "outpost" "lookup"
outpost_id="$(printf '%s' "$outpost_json" | jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' | head -n1)"
[[ -n "$outpost_id" && "$outpost_id" != "null" ]] || fail "Could not find the embedded Authentik outpost"

current_providers="$(printf '%s' "$outpost_json" | jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []')"
log "Embedded Authentik outpost currently has $(jq -r 'length' <<<"$current_providers") proxy provider(s)"
updated_providers="$(
  printf '%s\n' "$current_providers" \
    | jq --arg traefik "$traefik_provider_id" --arg longhorn "$longhorn_provider_id" --arg hubble "$hubble_provider_id" --arg proxmox "$proxmox_provider_id" --arg webwizard "$webwizard_provider_id" --arg seaweedfs "$seaweedfs_provider_id" --arg seaweedfs_admin "$seaweedfs_admin_provider_id" '
        . + [$traefik, $longhorn, $hubble, $proxmox, $webwizard]
        + [$seaweedfs, $seaweedfs_admin]
        | map(tostring)
        | unique
      '
)"

if [[ "$current_providers" != "$updated_providers" ]]; then
  log "Attaching management console proxy providers to embedded Authentik outpost"
  authentik_write_or_fail_context outpost_patch_response PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" \
    "authentik Embedded Outpost" "" "outpost" "attach providers"
else
  log "Embedded Authentik outpost already has all management console proxy providers"
fi

authentik_get_json_context final_outpost_json "/outposts/instances/${outpost_id}/" "authentik Embedded Outpost" "" "outpost" "verify"
final_provider_count="$(printf '%s' "$final_outpost_json" | jq -r '.providers | length')"
missing_consoles=()
while IFS= read -r app_json; do
  app_key="$(jq -r '.key' <<<"$app_json")"
  app_name="$(jq -r '.name' <<<"$app_json")"
  app_slug="$(jq -r '.slug' <<<"$app_json")"
  provider_id="$(jq -r --arg app_key "$app_key" '.[$app_key] // empty' <<<"$provider_ids_json")"
  application_id="$(jq -r --arg app_key "$app_key" '.[$app_key] // empty' <<<"$application_ids_json")"

  status="ready"
  if [[ -z "$provider_id" || -z "$application_id" ]]; then
    status="missing"
  elif ! printf '%s' "$final_outpost_json" | jq -e --arg provider_id "$provider_id" '
        (.providers // [])
        | map(tostring)
        | index($provider_id) != null
      ' >/dev/null; then
    status="not attached to outpost"
  fi

  log "Management console status: ${app_name} slug=${app_slug} provider=${provider_id:-missing} application=${application_id:-missing} status=${status}"
  if [[ "$status" != "ready" ]]; then
    missing_consoles+=("${app_name}: ${status}")
  fi
done < <(jq -c '.[]' <<<"$management_apps_json")

if [[ "${#missing_consoles[@]}" -gt 0 ]]; then
  fail "One or more management consoles are not ready: ${missing_consoles[*]}"
fi

clear_context
log "Embedded Authentik outpost now has ${final_provider_count} proxy provider(s)"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg traefik_route "traefik-dashboard" \
    --arg longhorn_route "longhorn" \
    --arg hubble_route "hubble" \
    --arg proxmox_route "proxmox" \
    --arg webwizard_route "webwizard" \
    --arg seaweedfs_route "seaweedfs" \
    --arg seaweedfs_admin_route "seaweedfs-admin" \
    '{
      traefik_route: $traefik_route,
      longhorn_route: $longhorn_route,
      hubble_route: $hubble_route,
      proxmox_route: $proxmox_route,
      webwizard_route: $webwizard_route,
      seaweedfs_route: $seaweedfs_route,
      seaweedfs_admin_route: $seaweedfs_admin_route
    }' >"$STEP_RESULT_FILE"
fi

# Source for zone lookup (already sourced at top of file)
cluster_dns_domain="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.dns_domain // empty')"
cluster_slug="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.slug // .cluster.id // empty')"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "traefik" \
  --service-domain "traefik.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "longhorn" \
  --service-domain "longhorn.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "hubble" \
  --service-domain "hubble.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "proxmox" \
  --service-domain "proxmox.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "seaweedfs" \
  --service-domain "seaweedfs.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "seaweedfs-admin" \
  --service-domain "seaweedfs-admin.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "webwizard" \
  --service-domain "webwizard.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /
