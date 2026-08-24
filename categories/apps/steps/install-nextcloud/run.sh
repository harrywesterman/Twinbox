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

find_ldap_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/ldap/?page_size=200")"
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

create_or_update_ldap_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_ldap_provider_pk_by_name "nextcloud-ldap")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/ldap/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/ldap/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_ldap_application() {
  local application_payload="$1"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "nextcloud-ldap" || true)"
  existing_pk=""
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  fi
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/nextcloud-ldap/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

find_role_pk_by_name() {
  local role_name="$1"
  local response

  response="$(authentik_api_get "/rbac/roles/?page_size=200")"
  jq -r \
    --arg role_name "$role_name" \
    '.results[]?
      | select((.name // "") == $role_name)
      | .pk // empty' <<<"$response" | head -n1
}

create_or_update_ldap_search_role() {
  local role_name="nextcloud-ldap-search"
  local existing_pk

  existing_pk="$(find_role_pk_by_name "$role_name")"
  if [[ -n "$existing_pk" ]]; then
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/rbac/roles/" "$(jq -n --arg name "$role_name" '{name: $name}')" | jq -r '.pk // empty'
}

find_user_json_by_username() {
  local username="$1"
  local response

  response="$(authentik_api_get "/core/users/?page_size=200&search=${username}")"
  jq -c \
    --arg username "$username" \
    '.results[]?
      | select((.username // "") == $username)' <<<"$response" | head -n1
}

create_or_update_ldap_bind_user() {
  local username="$1"
  local password="$2"
  local existing_json existing_pk payload

  payload="$(
    jq -n \
      --arg username "$username" \
      '{
        username: $username,
        name: "Nextcloud LDAP Bind",
        path: "nextcloud",
        type: "service_account",
        is_active: true
      }'
  )"

  existing_json="$(find_user_json_by_username "$username" || true)"
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // empty' <<<"$existing_json")"
    [[ -n "$existing_pk" ]] || fail "Could not determine Authentik user ID for ${username}"
    authentik_api_write PATCH "/core/users/${existing_pk}/" "$payload" >/dev/null
  else
    existing_pk="$(authentik_api_write POST "/core/users/" "$payload" | jq -r '.pk // empty')"
  fi

  [[ -n "$existing_pk" ]] || fail "Authentik did not return a user ID for ${username}"
  authentik_api_write POST "/core/users/${existing_pk}/set_password/" "$(jq -n --arg password "$password" '{password: $password}')" >/dev/null
  printf '%s\n' "$existing_pk"
}

update_authentik_user_nextcloud_uid() {
  local user_json="$1"
  local nextcloud_uid="$2"
  local user_pk current_user_json payload

  user_pk="$(jq -r '.pk // empty' <<<"$user_json")"
  [[ -n "$user_pk" ]] || fail "Could not determine Authentik user ID while setting nextcloudUid"
  current_user_json="$(authentik_api_get "/core/users/${user_pk}/")"

  payload="$(
    jq -c \
      --arg nextcloud_uid "$nextcloud_uid" \
      '{attributes: ((.attributes // {}) + {nextcloudUid: $nextcloud_uid})}' <<<"$current_user_json"
  )"
  authentik_api_write PATCH "/core/users/${user_pk}/" "$payload" >/dev/null
}

assign_ldap_search_permission() {
  local role_pk="$1"
  local user_pk="$2"
  local provider_pk="$3"
  local role_response has_role permission_response

  role_response="$(authentik_api_get "/rbac/roles/?users=${user_pk}&page_size=200")"
  has_role="$(
    jq -r \
      --arg role_pk "$role_pk" \
      'any(.results[]?; (.pk // "") == $role_pk)' <<<"$role_response"
  )"
  if [[ "$has_role" != "true" ]]; then
    authentik_api_write POST "/rbac/roles/${role_pk}/add_user/" "$(jq -n --argjson pk "$user_pk" '{pk: $pk}')" >/dev/null
  fi

  permission_response="$(authentik_api_get "/rbac/permissions/?codename=search_full_directory&content_type__app_label=authentik_providers_ldap&content_type__model=ldapprovider&page_size=100")"
  if ! jq -e '.results[]? | select((.codename // "") == "search_full_directory")' >/dev/null <<<"$permission_response"; then
    fail "Authentik permission search_full_directory for LDAP providers was not found"
  fi

  authentik_api_write POST "/rbac/permissions/assigned_by_roles/${role_pk}/assign/" "$(
    jq -n \
      --arg provider_pk "$provider_pk" \
      '{
        permissions: ["authentik_providers_ldap.search_full_directory"],
        model: "authentik_providers_ldap.ldapprovider",
        object_pk: $provider_pk
      }'
  )" >/dev/null
}

find_kubernetes_service_connection_pk() {
  local response

  response="$(authentik_api_get "/outposts/service_connections/kubernetes/?local=true&page_size=100")"
  jq -r '.results[]? | select(.local == true) | .pk // empty' <<<"$response" | head -n1
}

create_local_kubernetes_service_connection() {
  authentik_api_write POST "/outposts/service_connections/kubernetes/" "$(
    jq -n '{name: "Local Kubernetes", local: true, verify_ssl: true}'
  )" | jq -r '.pk // empty'
}

find_outpost_json_by_name() {
  local outpost_name="$1"
  local response

  response="$(authentik_api_get "/outposts/instances/?page_size=200")"
  jq -c \
    --arg outpost_name "$outpost_name" \
    '.results[]?
      | select((.name // "") == $outpost_name)' <<<"$response" | head -n1
}

create_or_update_ldap_outpost() {
  local provider_pk="$1"
  local service_connection_pk existing_json existing_pk default_config payload

  service_connection_pk="$(find_kubernetes_service_connection_pk)"
  if [[ -z "$service_connection_pk" ]]; then
    service_connection_pk="$(create_local_kubernetes_service_connection)"
  fi
  [[ -n "$service_connection_pk" ]] || fail "Could not create or resolve a local Authentik Kubernetes service connection"

  default_config="$(authentik_api_get "/outposts/instances/default_settings/" | jq -c '.config // {}')"
  payload="$(
    jq -n \
      --arg service_connection "$service_connection_pk" \
      --argjson provider_pk "$provider_pk" \
      --argjson config "$default_config" \
      '{
        name: "nextcloud-ldap",
        type: "ldap",
        providers: [$provider_pk],
        service_connection: $service_connection,
        config: $config
      }'
  )"

  existing_json="$(find_outpost_json_by_name "nextcloud-ldap" || true)"
  if [[ -n "$existing_json" ]]; then
    existing_pk="$(jq -r '.pk // empty' <<<"$existing_json")"
    [[ -n "$existing_pk" ]] || fail "Could not determine Authentik outpost ID for nextcloud-ldap"
    authentik_api_write PATCH "/outposts/instances/${existing_pk}/" "$payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/outposts/instances/" "$payload" | jq -r '.pk // empty'
}

mailu_api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local api_token body_b64 output status response

  api_token="$(openbao_read_global_secret_json mailu-runtime 2>/dev/null | jq -r '."api-token" // empty' || true)"
  [[ -n "$api_token" ]] || fail "Mailu API token not found; install Mailu before configuring Nextcloud Mail"

  body_b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
  if ! output="$(kubectl exec -n mailu deploy/mailu-admin -c admin -- \
    env MAILU_API_METHOD="$method" MAILU_API_PATH="$path" MAILU_API_BODY_B64="$body_b64" \
    sh -s <<'SH'
set -eu
api_base="http://127.0.0.1:8080/api/v1"
response_file="$(mktemp)"
body_file="$(mktemp)"
trap 'rm -f "$response_file" "$body_file"' EXIT
printf '%s' "${MAILU_API_BODY_B64}" | base64 -d >"$body_file"
if [ -s "$body_file" ]; then
  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X "${MAILU_API_METHOD}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${body_file}" \
    "${api_base}${MAILU_API_PATH}" || echo "000")"
else
  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X "${MAILU_API_METHOD}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    "${api_base}${MAILU_API_PATH}" || echo "000")"
  fi
printf 'STATUS:%s\n' "$status"
cat "$response_file"
SH
  )"; then
    fail "Mailu API ${method} ${path} failed inside mailu-admin"
  fi

  status="$(sed -n '1s/^STATUS://p' <<<"$output")"
  response="$(sed '1d' <<<"$output")"
  if [[ ! "$status" =~ ^2 ]]; then
    local body_snippet
    body_snippet="$(head -c 240 <<<"$response" 2>/dev/null || true)"
    fail "Mailu API ${method} ${path} failed with HTTP ${status}: ${body_snippet}"
  fi

  printf '%s\n' "$response"
}

mailu_create_auth_token() {
  local email="$1"
  local comment="$2"
  local payload

  payload="$(jq -n --arg comment "$comment" '{comment: $comment, AuthorizedIP: []}')"
  mailu_api_request POST "/tokenuser/$(printf '%s' "$email" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')" "$payload" |
    jq -r '.token // empty'
}

nextcloud_occ() {
  kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c "cd /var/www/html && php occ $*"
}

nextcloud_user_exists() {
  local username="$1"
  kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
    "cd /var/www/html && php occ user:info $(printf '%q' "$username") >/dev/null 2>&1"
}

nextcloud_mail_account_exists() {
  local username="$1"
  local email="$2"
  kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
    "cd /var/www/html && php occ mail:account:export $(printf '%q' "$username") 2>/dev/null | grep -F -- $(printf '%q' "$email") >/dev/null"
}

configure_nextcloud_mail_accounts() {
  local mail_domain="$1"
  local imap_hostname="mailu-dovecot.mailu.svc.cluster.local"
  local imap_port="143"
  local imap_security="none"
  local smtp_hostname="mailu-front.mailu.svc.cluster.local"
  local smtp_port="10025"
  local smtp_security="none"
  local api_token users_json total configured skipped failed

  log "Configuring Nextcloud Mail accounts for existing Nextcloud users"
  api_token="$(openbao_read_global_secret_json mailu-runtime 2>/dev/null | jq -r '."api-token" // empty' || true)"
  if [[ -z "$api_token" ]]; then
    log "Skipping Nextcloud Mail account sync because Mailu is not installed yet"
    return 0
  fi

  users_json="$(authentik_api_get "/core/users/?page_size=200" 2>/dev/null | jq '[.results[] | select(.email != null and .email != "") | {email, name, username}]')"
  total="$(jq length <<<"$users_json")"
  configured=0
  skipped=0
  failed=0

  while IFS= read -r user_entry; do
    local email username name mail_token
    email="$(jq -r '.email' <<<"$user_entry")"
    username="$(jq -r '.username // empty' <<<"$user_entry")"
    name="$(jq -r '.name // .username // .email' <<<"$user_entry")"

    if [[ -z "$username" || "$email" != *@${mail_domain} ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if ! nextcloud_user_exists "$username"; then
      log "  SKIP ${email}: Nextcloud user ${username} does not exist yet"
      skipped=$((skipped + 1))
      continue
    fi

    if nextcloud_mail_account_exists "$username" "$email"; then
      log "  SKIP ${email}: Nextcloud Mail account already exists"
      skipped=$((skipped + 1))
      continue
    fi

    mail_token="$(mailu_create_auth_token "$email" "Nextcloud Mail")"
    if [[ -z "$mail_token" ]]; then
      log "  FAIL ${email}: Mailu did not return a Nextcloud Mail token"
      failed=$((failed + 1))
      continue
    fi

    if kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
      "cd /var/www/html && php occ mail:account:create $(printf '%q' "$username") $(printf '%q' "$name") $(printf '%q' "$email") $(printf '%q' "$imap_hostname") $(printf '%q' "$imap_port") $(printf '%q' "$imap_security") $(printf '%q' "$email") $(printf '%q' "$mail_token") $(printf '%q' "$smtp_hostname") $(printf '%q' "$smtp_port") $(printf '%q' "$smtp_security") $(printf '%q' "$email") $(printf '%q' "$mail_token") password >/dev/null"; then
      configured=$((configured + 1))
      log "  OK   ${email}: Nextcloud Mail account configured"
    else
      failed=$((failed + 1))
      log "  FAIL ${email}: Nextcloud Mail account creation failed"
    fi
  done < <(jq -c '.[]' <<<"$users_json")

  log "Nextcloud Mail account sync complete: ${total} total, ${configured} configured, ${skipped} skipped, ${failed} failed"
  if ((failed > 0)); then
    fail "Nextcloud Mail account sync failed for ${failed} user(s)"
  fi
}

assert_nextcloud_user_ids_match_authentik() {
  local oidc_config provider_id mapping_uid users_json nextcloud_users_json auth_entry auth_username auth_email mapped_uid expected_id existing_id existing_email

  oidc_config="$(resolve_nextcloud_oidc_local_id_config)"
  IFS=$'\t' read -r provider_id mapping_uid <<<"$oidc_config"
  users_json="$(authentik_api_get "/core/users/?page_size=200" 2>/dev/null | jq -c '[.results[]? | select((.type // "") != "service_account" and (.email // "") != "" and (.username // "") != "") | {username, email, uid}]')"
  nextcloud_users_json="$(kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c "cd /var/www/html && php occ user:list --output=json" 2>/dev/null || true)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$nextcloud_users_json"; then
    log "Warning: Could not inspect existing Nextcloud users before LDAP activation"
    return 0
  fi

  while IFS= read -r auth_entry; do
    auth_username="$(jq -r '.username' <<<"$auth_entry")"
    auth_email="$(jq -r '.email' <<<"$auth_entry")"
    mapped_uid="$(authentik_user_mapped_uid_value "$auth_entry" "$mapping_uid")"
    [[ -n "$mapped_uid" ]] || fail "Could not derive ${mapping_uid} for Authentik user ${auth_username}"
    expected_id="$(compute_nextcloud_oidc_local_id "$provider_id" "$mapped_uid")"

    if jq -e --arg expected_id "$expected_id" 'has($expected_id)' >/dev/null <<<"$nextcloud_users_json"; then
      continue
    fi

    while IFS= read -r existing_id; do
      [[ "$existing_id" != "$nextcloud_admin_username" ]] || continue
      existing_email="$(
        kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
          "cd /var/www/html && php occ user:info $(printf '%q' "$existing_id") --output=json" 2>/dev/null |
          jq -r '.email // empty' 2>/dev/null || true
      )"
      if [[ -n "$existing_email" && "$existing_email" == "$auth_email" ]]; then
        fail "Existing Nextcloud user ${existing_id} has Authentik email ${auth_email}, but the OIDC-compatible LDAP nextcloudUid for ${auth_username} is ${expected_id}; stopping before LDAP activation to avoid account duplication"
      fi
    done < <(jq -r 'keys[]' <<<"$nextcloud_users_json")
  done < <(jq -c '.[]' <<<"$users_json")
}

wait_for_nextcloud_ldap_outpost() {
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n authentik get svc ak-outpost-nextcloud-ldap >/dev/null 2>&1; then
      if kubectl -n authentik get endpoints ak-outpost-nextcloud-ldap -o json 2>/dev/null |
        jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null; then
        log "Authentik Nextcloud LDAP outpost is ready"
        return 0
      fi
      log "Waiting for Authentik Nextcloud LDAP outpost endpoints (${attempt}/${attempts})"
    else
      log "Waiting for Authentik Nextcloud LDAP outpost service (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for Authentik Nextcloud LDAP outpost"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

resolve_nextcloud_oidc_local_id_config() {
  local app_config_json config_line provider_id mapping_uid unique_uid

  app_config_json="$(
    kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
      "cd /var/www/html && php occ config:list user_oidc --output=json"
  )"

  config_line="$(
    jq -r \
      --arg client_id "$nextcloud_oidc_client_id" \
      '
      (.apps.user_oidc // {}) as $cfg
      | [($cfg | keys[] | capture("^provider-(?<id>[0-9]+)-mappingUid$")?.id)] as $ids
      | ($ids | unique | sort_by(tonumber)) as $sorted_ids
      | $sorted_ids[]
      | . as $id
      | select(
          (($cfg["provider-\($id)-clientId"] // $cfg["provider-\($id)-clientid"] // "") == $client_id)
          or (($cfg["provider-\($id)-identifier"] // $cfg["provider-\($id)-providerIdentifier"] // "") == "nextcloud")
          or (($sorted_ids | length) == 1)
        )
      | [$id, ($cfg["provider-\($id)-mappingUid"] // ""), ($cfg["provider-\($id)-uniqueUid"] // "")]
      | @tsv
      ' <<<"$app_config_json" | head -n1
  )"
  [[ -n "$config_line" ]] || fail "Could not resolve Nextcloud user_oidc provider config for nextcloud"

  IFS=$'\t' read -r provider_id mapping_uid unique_uid <<<"$config_line"
  [[ -n "$provider_id" ]] || fail "Could not resolve Nextcloud user_oidc provider ID"
  [[ -n "$mapping_uid" ]] || fail "Could not resolve Nextcloud user_oidc mappingUid for provider ${provider_id}"
  if [[ "$unique_uid" != "1" && "$unique_uid" != "true" ]]; then
    fail "Nextcloud user_oidc provider ${provider_id} does not have uniqueUid enabled; refusing to calculate LDAP-compatible user IDs"
  fi

  printf '%s\t%s\n' "$provider_id" "$mapping_uid"
}

authentik_user_mapped_uid_value() {
  local user_json="$1"
  local mapping_uid="$2"

  case "$mapping_uid" in
    preferred_username | username)
      jq -r '.username // empty' <<<"$user_json"
      ;;
    email)
      jq -r '.email // empty' <<<"$user_json"
      ;;
    sub | uid)
      jq -r '.uid // empty' <<<"$user_json"
      ;;
    *)
      fail "Unsupported Nextcloud user_oidc mappingUid ${mapping_uid}; add a safe LDAP nextcloudUid mapping before enabling LDAP"
      ;;
  esac
}

compute_nextcloud_oidc_local_id() {
  local provider_id="$1"
  local mapped_uid="$2"

  python3 - "$provider_id" "$mapped_uid" <<'PY'
import hashlib
import sys

provider_id = sys.argv[1]
mapped_uid = sys.argv[2]
print(hashlib.sha256(f"{provider_id}_0_{mapped_uid}".encode()).hexdigest())
PY
}

sync_authentik_nextcloud_ldap_uids() {
  local oidc_config provider_id mapping_uid users_json user_entry mapped_uid nextcloud_uid username email
  local total=0

  oidc_config="$(resolve_nextcloud_oidc_local_id_config)"
  IFS=$'\t' read -r provider_id mapping_uid <<<"$oidc_config"

  log "Syncing Authentik nextcloudUid attributes from Nextcloud user_oidc provider ${provider_id} (${mapping_uid})"
  users_json="$(
    authentik_api_get "/core/users/?page_size=200" 2>/dev/null |
      jq -c '[.results[]? | select((.type // "") != "service_account" and (.email // "") != "" and (.username // "") != "")]'
  )"

  while IFS= read -r user_entry; do
    username="$(jq -r '.username // empty' <<<"$user_entry")"
    email="$(jq -r '.email // empty' <<<"$user_entry")"
    mapped_uid="$(authentik_user_mapped_uid_value "$user_entry" "$mapping_uid")"
    [[ -n "$mapped_uid" ]] || fail "Could not derive ${mapping_uid} for Authentik user ${username:-$email}"

    nextcloud_uid="$(compute_nextcloud_oidc_local_id "$provider_id" "$mapped_uid")"
    update_authentik_user_nextcloud_uid "$user_entry" "$nextcloud_uid"
    total=$((total + 1))
  done < <(jq -c '.[]' <<<"$users_json")

  log "Synced nextcloudUid for ${total} Authentik user(s)"
}

configure_nextcloud_ldap_backend() {
  local ldap_bind_dn="$1"
  local ldap_bind_password="$2"
  local ldap_base_dn="$3"

  log "Configuring Nextcloud LDAP backend for Authentik directory"
  kubectl exec -i -n nextcloud deploy/nextcloud -c nextcloud -- \
    env \
      NEXTCLOUD_LDAP_BIND_DN="$ldap_bind_dn" \
      NEXTCLOUD_LDAP_BIND_PASSWORD="$ldap_bind_password" \
      NEXTCLOUD_LDAP_BASE_DN="$ldap_base_dn" \
    sh -s <<'SH'
set -euo pipefail
cd /var/www/html

if ! php -m | grep -Eiq '^ldap$'; then
  echo "Nextcloud image does not have the PHP LDAP extension enabled; user_ldap cannot be configured" >&2
  exit 1
fi

php occ app:install user_ldap >/dev/null 2>&1 || true
php occ app:enable user_ldap >/dev/null

config_id=""
for candidate in $({ php occ ldap:show-config 2>/dev/null || true; } | awk -F'|' '$2 ~ /Configuration/ {gsub(/[[:space:]]/, "", $3); if ($3 != "") print $3}'); do
  candidate_base="$(php occ ldap:show-config "$candidate" 2>/dev/null | awk -F'|' '$2 ~ /^[[:space:]]*ldapBase[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3; exit}')"
  if [ "$candidate_base" = "$NEXTCLOUD_LDAP_BASE_DN" ]; then
    config_id="$candidate"
    break
  fi
done

if [ -z "$config_id" ]; then
  config_id="$(php occ ldap:create-empty-config | grep -Eo 's[0-9]+' | head -n1)"
fi
[ -n "$config_id" ] || { echo "Could not create or locate a Nextcloud LDAP config ID" >&2; exit 1; }

php occ ldap:set-config "$config_id" ldapHost "ak-outpost-nextcloud-ldap.authentik.svc.cluster.local" >/dev/null
php occ ldap:set-config "$config_id" ldapPort "389" >/dev/null
php occ ldap:set-config "$config_id" ldapAgentName "$NEXTCLOUD_LDAP_BIND_DN" >/dev/null
php occ ldap:set-config "$config_id" ldapAgentPassword "$NEXTCLOUD_LDAP_BIND_PASSWORD" >/dev/null
php occ ldap:set-config "$config_id" ldapBase "$NEXTCLOUD_LDAP_BASE_DN" >/dev/null
php occ ldap:set-config "$config_id" ldapBaseUsers "ou=users,$NEXTCLOUD_LDAP_BASE_DN" >/dev/null
php occ ldap:set-config "$config_id" ldapBaseGroups "ou=groups,$NEXTCLOUD_LDAP_BASE_DN" >/dev/null
php occ ldap:set-config "$config_id" ldapUserFilterObjectclass "user" >/dev/null
php occ ldap:set-config "$config_id" ldapGroupFilterObjectclass "group" >/dev/null
php occ ldap:set-config "$config_id" ldapLoginFilter "(&(objectclass=user)(nextcloudUid=%uid))" >/dev/null
php occ ldap:set-config "$config_id" ldapExpertUsernameAttr "nextcloudUid" >/dev/null
php occ ldap:set-config "$config_id" ldapExpertUUIDUserAttr "nextcloudUid" >/dev/null
php occ ldap:set-config "$config_id" ldapExpertUUIDGroupAttr "gidNumber" >/dev/null
php occ ldap:set-config "$config_id" ldapUserDisplayName "name" >/dev/null
php occ ldap:set-config "$config_id" ldapGroupDisplayName "cn" >/dev/null
php occ ldap:set-config "$config_id" ldapEmailAttribute "mail" >/dev/null
php occ ldap:set-config "$config_id" ldapGroupMemberAssocAttr "member" >/dev/null
php occ ldap:set-config "$config_id" ldapConfigurationActive "1" >/dev/null

php occ ldap:test-config "$config_id"
php occ config:app:set dav system_addressbook_exposed --value="yes" >/dev/null
php occ dav:sync-system-addressbook >/dev/null 2>&1 || true
SH
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
NEXTCLOUD_DOMAIN="${NEXTCLOUD_HOST#https://}"
NEXTCLOUD_OIDC_REDIRECT_URI="${NEXTCLOUD_HOST}/index.php/apps/user_oidc/code"
NEXTCLOUD_OIDC_REDIRECT_URI_PRETTY="${NEXTCLOUD_HOST}/apps/user_oidc/code"
NEXTCLOUD_OIDC_LOGOUT_URI="${NEXTCLOUD_HOST}/index.php/apps/user_oidc/sls"
NEXTCLOUD_OIDC_LOGOUT_URI_PRETTY="${NEXTCLOUD_HOST}/apps/user_oidc/sls"
NEXTCLOUD_OIDC_BACKCHANNEL_URI="${NEXTCLOUD_HOST}/index.php/apps/user_oidc/backchannel-logout/nextcloud"
NEXTCLOUD_OIDC_BACKCHANNEL_URI_PRETTY="${NEXTCLOUD_HOST}/apps/user_oidc/backchannel-logout/nextcloud"

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
oidc_groups_mapping_release_url="https://github.com/strobelpierre/nextcloud_oidc_groups_mapping/releases/latest/download/oidc_groups_mapping.tar.gz"

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
nextcloud_eurooffice_jwt_secret="$(openssl rand -hex 32)"
nextcloud_ldap_bind_username="nextcloud-ldap-bind"
nextcloud_ldap_bind_password="$(openssl rand -hex 24)"
nextcloud_ldap_base_dn="ou=nextcloud,dc=ldap,dc=goauthentik,dc=io"

if [[ -n "$existing_nextcloud_secret_json" ]]; then
  nextcloud_admin_username="$(jq -r '.NEXTCLOUD_ADMIN_USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_admin_password="$(jq -r '.NEXTCLOUD_ADMIN_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_db_username="$(jq -r '.NEXTCLOUD_POSTGRESQL__USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_db_password="$(jq -r '.NEXTCLOUD_POSTGRESQL__PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_redis_password="$(jq -r '.NEXTCLOUD_REDIS_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_oidc_client_id="$(jq -r '.NEXTCLOUD_OIDC_CLIENT_ID // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_oidc_client_secret="$(jq -r '.NEXTCLOUD_OIDC_CLIENT_SECRET // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_eurooffice_jwt_secret="$(jq -r '.EUROOFFICE_JWT_SECRET // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_ldap_bind_username="$(jq -r '.NEXTCLOUD_LDAP_BIND_USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_ldap_bind_password="$(jq -r '.NEXTCLOUD_LDAP_BIND_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_ldap_base_dn="$(jq -r '.NEXTCLOUD_LDAP_BASE_DN // empty' <<<"$existing_nextcloud_secret_json" || true)"
fi

[[ -n "$nextcloud_admin_username" ]] || nextcloud_admin_username="admin"
[[ -n "$nextcloud_admin_password" ]] || nextcloud_admin_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_db_username" ]] || nextcloud_db_username="nextcloud"
[[ -n "$nextcloud_db_password" ]] || nextcloud_db_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_redis_password" ]] || nextcloud_redis_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_oidc_client_id" ]] || nextcloud_oidc_client_id="$(openssl rand -hex 16)"
[[ -n "$nextcloud_oidc_client_secret" ]] || nextcloud_oidc_client_secret="$(openssl rand -hex 32)"
[[ -n "$nextcloud_eurooffice_jwt_secret" ]] || nextcloud_eurooffice_jwt_secret="$(openssl rand -hex 32)"
[[ -n "$nextcloud_ldap_bind_username" ]] || nextcloud_ldap_bind_username="nextcloud-ldap-bind"
[[ -n "$nextcloud_ldap_bind_password" ]] || nextcloud_ldap_bind_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_ldap_base_dn" ]] || nextcloud_ldap_base_dn="ou=nextcloud,dc=ldap,dc=goauthentik,dc=io"
nextcloud_ldap_bind_dn="cn=${nextcloud_ldap_bind_username},ou=users,${nextcloud_ldap_base_dn}"

nextcloud_secret_file="$(mktemp)"
trap 'rm -f "$nextcloud_secret_file"' EXIT
jq -n \
  --arg nextcloud_admin_username "$nextcloud_admin_username" \
  --arg nextcloud_admin_password "$nextcloud_admin_password" \
  --arg nextcloud_postgresql_username "$nextcloud_db_username" \
  --arg nextcloud_postgresql_password "$nextcloud_db_password" \
  --arg nextcloud_redis_password "$nextcloud_redis_password" \
  --arg nextcloud_oidc_client_id "$nextcloud_oidc_client_id" \
  --arg nextcloud_oidc_client_secret "$nextcloud_oidc_client_secret" \
  --arg eurooffice_jwt_secret "$nextcloud_eurooffice_jwt_secret" \
  --arg nextcloud_ldap_bind_username "$nextcloud_ldap_bind_username" \
  --arg nextcloud_ldap_bind_password "$nextcloud_ldap_bind_password" \
  --arg nextcloud_ldap_base_dn "$nextcloud_ldap_base_dn" \
  '{
    "NEXTCLOUD_ADMIN_USERNAME": $nextcloud_admin_username,
    "NEXTCLOUD_ADMIN_PASSWORD": $nextcloud_admin_password,
    "NEXTCLOUD_POSTGRESQL__USERNAME": $nextcloud_postgresql_username,
    "NEXTCLOUD_POSTGRESQL__PASSWORD": $nextcloud_postgresql_password,
    "NEXTCLOUD_REDIS_PASSWORD": $nextcloud_redis_password,
    "NEXTCLOUD_OIDC_CLIENT_ID": $nextcloud_oidc_client_id,
    "NEXTCLOUD_OIDC_CLIENT_SECRET": $nextcloud_oidc_client_secret,
    "EUROOFFICE_JWT_SECRET": $eurooffice_jwt_secret,
    "NEXTCLOUD_LDAP_BIND_USERNAME": $nextcloud_ldap_bind_username,
    "NEXTCLOUD_LDAP_BIND_PASSWORD": $nextcloud_ldap_bind_password,
    "NEXTCLOUD_LDAP_BASE_DN": $nextcloud_ldap_base_dn
  }' >"$nextcloud_secret_file"

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
signing_key_id="$(authentik_resolve_signing_key_id)"
[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"

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
if ak_is_group_member(request.user, name="admins") and "admin" not in groups:
    groups.append("admin")
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
    --arg signing_key "$signing_key_id" \
    --argjson property_mappings "$(jq -cn \
      --arg openid "$openid_mapping_id" \
      --arg email "$email_mapping_id" \
      --arg profile "$nextcloud_profile_mapping_id" \
      --arg groups "$nextcloud_groups_mapping_id" \
      '[$openid, $email, $profile, $groups]'
    )" \
    --arg redirect_login "$NEXTCLOUD_OIDC_REDIRECT_URI" \
    --arg redirect_login_pretty "$NEXTCLOUD_OIDC_REDIRECT_URI_PRETTY" \
    --arg redirect_logout "$NEXTCLOUD_OIDC_LOGOUT_URI" \
    --arg redirect_logout_pretty "$NEXTCLOUD_OIDC_LOGOUT_URI_PRETTY" \
    --arg redirect_backchannel "$NEXTCLOUD_OIDC_BACKCHANNEL_URI" \
    --arg redirect_backchannel_pretty "$NEXTCLOUD_OIDC_BACKCHANNEL_URI_PRETTY" \
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
          url: $redirect_login
        },
        {
          matching_mode: "strict",
          url: $redirect_login_pretty
        },
        {
          matching_mode: "strict",
          url: $redirect_logout
        },
        {
          matching_mode: "strict",
          url: $redirect_logout_pretty
        },
        {
          matching_mode: "strict",
          url: $redirect_backchannel
        },
        {
          matching_mode: "strict",
          url: $redirect_backchannel_pretty
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

ldap_provider_payload="$(
  jq -n \
    --arg name "nextcloud-ldap" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg base_dn "$nextcloud_ldap_base_dn" \
    '{
      name: $name,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      base_dn: $base_dn,
      search_mode: "cached",
      bind_mode: "cached",
      mfa_support: false
    }'
)"
ldap_provider_pk="$(create_or_update_ldap_provider "$ldap_provider_payload")"
[[ -n "$ldap_provider_pk" ]] || fail "Authentik did not return a provider ID for nextcloud-ldap"

ldap_application_payload="$(
  jq -n \
    --arg name "nextcloud-ldap" \
    --arg slug "nextcloud-ldap" \
    --arg provider_pk "$ldap_provider_pk" \
    '{
      name: $name,
      slug: $slug,
      provider: ($provider_pk | tonumber)
    }'
)"
ldap_application_pk="$(create_or_update_ldap_application "$ldap_application_payload")"
[[ -n "$ldap_application_pk" ]] || fail "Authentik did not return an application ID for nextcloud-ldap"

ldap_bind_user_pk="$(create_or_update_ldap_bind_user "$nextcloud_ldap_bind_username" "$nextcloud_ldap_bind_password")"
ldap_search_role_pk="$(create_or_update_ldap_search_role)"
[[ -n "$ldap_search_role_pk" ]] || fail "Authentik did not return a role ID for nextcloud-ldap-search"
assign_ldap_search_permission "$ldap_search_role_pk" "$ldap_bind_user_pk" "$ldap_provider_pk"

ldap_outpost_pk="$(create_or_update_ldap_outpost "$ldap_provider_pk")"
[[ -n "$ldap_outpost_pk" ]] || fail "Authentik did not return an outpost ID for nextcloud-ldap"

log "Syncing Nextcloud bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "nextcloud" \
  --json-file "$nextcloud_secret_file" \
  --required-keys "NEXTCLOUD_ADMIN_USERNAME,NEXTCLOUD_ADMIN_PASSWORD,NEXTCLOUD_POSTGRESQL__USERNAME,NEXTCLOUD_POSTGRESQL__PASSWORD,NEXTCLOUD_REDIS_PASSWORD,NEXTCLOUD_OIDC_CLIENT_ID,NEXTCLOUD_OIDC_CLIENT_SECRET,EUROOFFICE_JWT_SECRET,NEXTCLOUD_LDAP_BIND_USERNAME,NEXTCLOUD_LDAP_BIND_PASSWORD,NEXTCLOUD_LDAP_BASE_DN"
log "Applying Nextcloud Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/optional-apps/nextcloud.yaml" \
  --application "nextcloud"

wait_for_nextcloud_ldap_outpost

log "Waiting for Euro-Office Document Server"
wait_for_deployment_rollout "nextcloud" "nextcloud-eurooffice" "Euro-Office Document Server"

bash "$WORKSPACE_ROOT/scripts/manager/sync-pgadmin4-server.sh" \
  --app-id "nextcloud" \
  --host "nextcloud-db-pooler-rw.databases.svc.cluster.local"

log "Checking whether Nextcloud is already installed"
init_success=false
pod=$(kubectl -n nextcloud get pods -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$pod" ]]; then
  status_json=$(kubectl -n nextcloud exec "$pod" -- php -r 'echo file_get_contents("http://localhost/status.php");' 2>/dev/null || true)
  if [[ "$status_json" =~ \"installed\":(true|false) ]]; then
    installed_status="${BASH_REMATCH[1]}"
    if [[ "$installed_status" == "true" ]]; then
      log "Nextcloud is already installed; skipping initialization job"
      init_success=true
    fi
  fi
fi

if [[ "$init_success" != "true" ]]; then
  log "Installing Nextcloud"
  kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
    set -euo pipefail
    cd /var/www/html
    su -s /bin/bash www-data -c \"php occ maintenance:install \\
      --database=pgsql \\
      --database-host='nextcloud-db-pooler-rw.databases.svc.cluster.local' \\
      --database-port='5432' \\
      --database-name='nextcloud' \\
      --database-user='${nextcloud_db_username}' \\
      --database-pass='${nextcloud_db_password}' \\
      --admin-user='${nextcloud_admin_username}' \\
      --admin-pass='${nextcloud_admin_password}' \\
      --data-dir='/var/www/html/data'\"
  "
  init_success=true
fi

log "Verifying Nextcloud installation status"
verify_attempts=30
verify_attempt=1
while [[ $verify_attempt -le $verify_attempts ]]; do
  pod=$(kubectl -n nextcloud get pods -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$pod" ]]; then
    status_json=$(kubectl -n nextcloud exec "$pod" -- php -r 'echo file_get_contents("http://localhost/status.php");' 2>/dev/null || true)
    if [[ "$status_json" =~ \"installed\":(true|false) ]]; then
      installed_status="${BASH_REMATCH[1]}"
    else
      installed_status="unknown"
    fi
    if [[ "$installed_status" == "true" ]]; then
      log "Nextcloud is initialized"
      break
    fi
  fi
  
  if [[ $verify_attempt -ge $verify_attempts ]]; then
    log "Warning: Could not verify Nextcloud installation status, proceeding anyway"
  fi
  
  sleep 10
  verify_attempt=$((verify_attempt + 1))
done

wait_for_statefulset_ready "nextcloud" "nextcloud-redis-master" "Nextcloud Redis master"

log "Updating Nextcloud trusted domains"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
  set -euo pipefail
  cd /var/www/html
  php occ config:system:set trusted_domains 1 --value='${NEXTCLOUD_DOMAIN}' --type=string
"

log "Configuring Nextcloud Redis memcache for HA"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
  set -euo pipefail
  cd /var/www/html
  php occ config:system:set memcache.distributed --value='\\OC\\Memcache\\Redis' --type=string
  php occ config:system:set memcache.local --value='\\OC\\Memcache\\APCu' --type=string
  php occ config:system:set memcache.locking --value='\\OC\\Memcache\\Redis' --type=string
  php occ config:system:set redis --value='host:nextcloud-redis-master,port:6379' --type=string
"

log "Bootstrapping Nextcloud user_oidc"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
  set -euo pipefail
  cd /var/www/html
  php occ app:install user_oidc >/dev/null 2>&1 || true
  php occ app:enable user_oidc >/dev/null
  php occ config:app:set --type=string --value=1 user_oidc allow_multiple_user_backends
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
    --group-provisioning='1' \
    --group-restrict-login-to-whitelist='0' \
    --unique-uid='1' \
    --check-bearer='0' \
    --bearer-provisioning='0' \
    --send-id-token-hint='1' \
    --resolve-nested-claims='1'
  # user_oidc does not always persist the provider's group provisioning toggle
  # through the provider CLI, so write the app config explicitly as well.
  php occ config:app:set --type=string --value=1 user_oidc provider-1-groupProvisioning
"

log "Installing Nextcloud OIDC groups mapping"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
  set -euo pipefail
  cd /var/www/html

  if [ ! -d custom_apps/oidc_groups_mapping/appinfo ]; then
    tmp_dir=\"\$(mktemp -d)\"
    trap 'rm -rf \"\$tmp_dir\"' EXIT
    wget -qO \"\$tmp_dir/oidc_groups_mapping.tar.gz\" '${oidc_groups_mapping_release_url}'
    tar -xzf \"\$tmp_dir/oidc_groups_mapping.tar.gz\" -C \"\$tmp_dir\"
    rm -rf custom_apps/oidc_groups_mapping
    mv \"\$tmp_dir/oidc_groups_mapping\" custom_apps/oidc_groups_mapping
  fi

  php occ app:enable -f oidc_groups_mapping >/dev/null
  php occ oidc-groups:set '{
    \"version\": 1,
    \"mode\": \"additive\",
    \"rules\": [
      {
        \"id\": \"admins-to-admin\",
        \"type\": \"map\",
        \"enabled\": true,
        \"claimPath\": \"groups\",
        \"config\": {
          \"values\": {
            \"admins\": \"admin\"
          },
          \"unmappedPolicy\": \"ignore\"
        }
      }
    ]
  }' >/dev/null
"

sync_authentik_nextcloud_ldap_uids
assert_nextcloud_user_ids_match_authentik
configure_nextcloud_ldap_backend "$nextcloud_ldap_bind_dn" "$nextcloud_ldap_bind_password" "$nextcloud_ldap_base_dn"

log "Installing recommended Nextcloud apps"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc "
  set -euo pipefail
  cd /var/www/html

  # Office
  php occ app:install richdocuments >/dev/null 2>&1 || true
  php occ app:install eurooffice >/dev/null 2>&1 || true
  
  # Groupware
  php occ app:install calendar >/dev/null 2>&1 || true
  php occ app:install contacts >/dev/null 2>&1 || true
  php occ app:install mail >/dev/null 2>&1 || true
  
  # Productivity
  php occ app:install talk >/dev/null 2>&1 || true
  php occ app:install deck >/dev/null 2>&1 || true
  php occ app:install notes >/dev/null 2>&1 || true
  php occ app:install tables >/dev/null 2>&1 || true
  
  # Media
  php occ app:install photos >/dev/null 2>&1 || true
  
  # Enable all installed apps
  php occ app:enable richdocuments >/dev/null 2>&1 || true
  php occ app:enable eurooffice >/dev/null
  php occ app:enable calendar >/dev/null 2>&1 || true
  php occ app:enable contacts >/dev/null 2>&1 || true
  php occ app:enable mail >/dev/null 2>&1 || true
  php occ app:enable talk >/dev/null 2>&1 || true
  php occ app:enable deck >/dev/null 2>&1 || true
  php occ app:enable notes >/dev/null 2>&1 || true
  php occ app:enable tables >/dev/null 2>&1 || true
  php occ app:enable photos >/dev/null 2>&1 || true
  php occ app:enable activity >/dev/null 2>&1 || true
"

configure_nextcloud_mail_accounts "$public_zone_name"

log "Configuring Collabora WOPI URL"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ config:system:set wopi_url --value='https://nextcloud-collabora.${public_zone_name}' --type=string" || true
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ config:app:set --value='https://nextcloud-collabora.${public_zone_name}' richdocuments wopi_url && php occ richdocuments:activate-config" || true

log "Configuring Euro-Office Document Server"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ config:app:set eurooffice DocumentServerUrl --value='https://nextcloud-eurooffice.${public_zone_name}/' --type=string &&
   php occ config:app:set eurooffice DocumentServerInternalUrl --value='http://nextcloud-eurooffice.nextcloud.svc.cluster.local/' --type=string &&
   php occ config:app:set eurooffice StorageUrl --value='${NEXTCLOUD_HOST}/' --type=string &&
   php occ config:app:set eurooffice jwt_secret --value='${nextcloud_eurooffice_jwt_secret}' --type=string >/dev/null 2>&1 &&
   php occ config:app:set eurooffice jwt_header --value='AuthorizationJWT' --type=string &&
   php occ config:app:set eurooffice sameTab --value='false' --type=string --no-interaction &&
   php occ config:app:set eurooffice enableSharing --value='true' --type=string --no-interaction &&
   php occ config:app:set eurooffice preview --value='false' --type=string --no-interaction"

log "Installing Twinbox EuroOffice Files action"
tar -C "$WORKSPACE_ROOT/categories/apps/steps/install-nextcloud" -cf - eurooffice-file-action \
  | kubectl exec -i -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc '
    set -eu
    cd /var/www/html/custom_apps
    rm -rf twinbox_eurooffice_action
    tar -xf -
    mv eurooffice-file-action twinbox_eurooffice_action
    chown -R www-data:www-data twinbox_eurooffice_action
  '
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ app:enable twinbox_eurooffice_action >/dev/null"

log "Configuring Nextcloud Talk STUN/TURN servers"
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ config:system:set stun_servers --value='[\"turn.${public_zone_name}:3478\"]' --type=json" || true
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ config:app:set --value='yes' --type=string talk signaling" || true

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

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "nextcloud" \
  --service-domain "nextcloud.${public_zone_name}" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "nextcloud-collabora" \
  --service-domain "nextcloud-collabora.${public_zone_name}" \
  --service-path /

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "nextcloud-eurooffice" \
  --service-domain "nextcloud-eurooffice.${public_zone_name}" \
  --service-path /
