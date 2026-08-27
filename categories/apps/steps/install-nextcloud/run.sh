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
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

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
    -H "Authorization: Bearer ${MAILU_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${body_file}" \
    "${api_base}${MAILU_API_PATH}" || echo "000")"
else
  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X "${MAILU_API_METHOD}" \
    -H "Authorization: Bearer ${MAILU_API_TOKEN}" \
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

install_nextcloud_scim() {
  local pod installed_version release_url temp_dir tarball archive_list archive_entry actual_version

  : "${PINNED_NEXTCLOUD_SCIM_SP_VERSION:?missing PINNED_NEXTCLOUD_SCIM_SP_VERSION}"
  : "${PINNED_NEXTCLOUD_SCIM_SP_SHA256:?missing PINNED_NEXTCLOUD_SCIM_SP_SHA256}"
  [[ "$PINNED_NEXTCLOUD_SCIM_SP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "Invalid PINNED_NEXTCLOUD_SCIM_SP_VERSION: $PINNED_NEXTCLOUD_SCIM_SP_VERSION"
  [[ "$PINNED_NEXTCLOUD_SCIM_SP_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
    fail "Invalid PINNED_NEXTCLOUD_SCIM_SP_SHA256"

  pod="$(kubectl -n nextcloud get pod -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || fail "Could not determine the Nextcloud pod for scim_sp installation"
  installed_version="$(
    kubectl exec -n nextcloud "$pod" -c nextcloud -- php /var/www/html/occ app:list --output=json 2>/dev/null |
      jq -r '.enabled.scim_sp // .disabled.scim_sp // empty' || true
  )"
  if [[ "$installed_version" == "$PINNED_NEXTCLOUD_SCIM_SP_VERSION" ]]; then
    log "scim_sp $installed_version is already installed"
    kubectl exec -n nextcloud "$pod" -c nextcloud -- \
      php /var/www/html/occ app:enable -f scim_sp >/dev/null
    return 0
  fi

  release_url="https://github.com/harrywesterman/nextcloud-scim-sp/releases/download/v${PINNED_NEXTCLOUD_SCIM_SP_VERSION}/scim_sp.tar.gz"
  temp_dir="$(mktemp -d)"
  tarball="$temp_dir/scim_sp.tar.gz"
  log "Downloading pinned scim_sp v${PINNED_NEXTCLOUD_SCIM_SP_VERSION} release"
  if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "$tarball" "$release_url"; then
    rm -rf "$temp_dir"
    fail "Could not download pinned scim_sp release"
  fi
  if ! printf '%s  %s\n' "$PINNED_NEXTCLOUD_SCIM_SP_SHA256" "$tarball" | sha256sum -c - >/dev/null; then
    rm -rf "$temp_dir"
    fail "scim_sp release checksum verification failed"
  fi
  archive_list="$temp_dir/archive.list"
  if ! tar -tzf "$tarball" >"$archive_list" || [[ ! -s "$archive_list" ]]; then
    rm -rf "$temp_dir"
    fail "scim_sp release is not a readable non-empty tarball"
  fi
  while IFS= read -r archive_entry; do
    if [[ -z "$archive_entry" || "$archive_entry" != scim_sp/* || "$archive_entry" == /* || "$archive_entry" == *"../"* ]]; then
      rm -rf "$temp_dir"
      fail "scim_sp release contains an unsafe archive path"
    fi
  done <"$archive_list"

  log "Installing scim_sp $PINNED_NEXTCLOUD_SCIM_SP_VERSION into the Nextcloud PVC"
  kubectl cp "$tarball" "nextcloud/$pod:/tmp/scim_sp.tar.gz" -c nextcloud >/dev/null
  # The inner variables belong to the shell running inside the Nextcloud pod.
  # shellcheck disable=SC2016
  if ! kubectl exec -n nextcloud "$pod" -c nextcloud -- \
    env EXPECTED_SCIM_VERSION="$PINNED_NEXTCLOUD_SCIM_SP_VERSION" sh -lc '
    set -euo pipefail
    apps_dir=/var/www/html/custom_apps
    staging_dir="$apps_dir/.scim_sp.next"
    previous_dir="$apps_dir/.scim_sp.previous"
    rm -rf "$staging_dir" "$previous_dir"
    mkdir -p "$staging_dir"
    tar -xzf /tmp/scim_sp.tar.gz -C "$staging_dir" --strip-components=1
    test -f "$staging_dir/appinfo/info.xml"
    grep -Fq "<version>${EXPECTED_SCIM_VERSION}</version>" "$staging_dir/appinfo/info.xml"
    chown -R www-data:www-data "$staging_dir"
    if [ -d "$apps_dir/scim_sp" ]; then
      mv "$apps_dir/scim_sp" "$previous_dir"
    fi
    mv "$staging_dir" "$apps_dir/scim_sp"
    if ! su -s /bin/bash www-data -c "cd /var/www/html && php occ upgrade --no-interaction && php occ app:enable -f scim_sp" >/dev/null; then
      rm -rf "$apps_dir/scim_sp"
      if [ -d "$previous_dir" ]; then
        mv "$previous_dir" "$apps_dir/scim_sp"
      fi
      exit 1
    fi
    rm -rf "$previous_dir"
    rm -f /tmp/scim_sp.tar.gz
  '; then
    rm -rf "$temp_dir"
    fail "Could not install scim_sp in Nextcloud"
  fi
  rm -rf "$temp_dir"

  kubectl -n nextcloud rollout restart deployment/nextcloud >/dev/null
  wait_for_deployment_rollout nextcloud nextcloud "Nextcloud after scim_sp update"
  pod="$(kubectl -n nextcloud get pod -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}')"
  actual_version="$(
    kubectl exec -n nextcloud "$pod" -c nextcloud -- php /var/www/html/occ app:list --output=json |
      jq -r '.enabled.scim_sp // empty'
  )"
  [[ "$actual_version" == "$PINNED_NEXTCLOUD_SCIM_SP_VERSION" ]] || \
    fail "scim_sp version mismatch after installation: expected $PINNED_NEXTCLOUD_SCIM_SP_VERSION, got ${actual_version:-missing}"
  log "scim_sp $actual_version installed and enabled"
}

provision_nextcloud_scim() {
  local pod scim_url existing_scim_token scim_token user_mapping_pk group_mapping_pk trusted_domain

  pod="$(kubectl -n nextcloud get pod -l app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || fail "Could not determine the Nextcloud pod for SCIM provisioning"

  log "Provisioning Authentik for the installed scim_sp app"

  # Ensure the in-cluster SCIM URL host is a trusted domain.
  scim_url="http://nextcloud.nextcloud.svc.cluster.local:8080/index.php/apps/scim_sp/scim/v2"
  for trusted_domain in nextcloud.nextcloud.svc.cluster.local nextcloud.nextcloud.svc.cluster.local:8080; do
    if ! kubectl exec -n nextcloud "$pod" -c nextcloud -- php /var/www/html/occ config:system:get trusted_domains 2>/dev/null | grep -Fxq "$trusted_domain"; then
      local td_idx
      td_idx="$(kubectl exec -n nextcloud "$pod" -c nextcloud -- php /var/www/html/occ config:system:get trusted_domains 2>/dev/null | grep -c . || true)"
      kubectl exec -n nextcloud "$pod" -c nextcloud -- php /var/www/html/occ \
        config:system:set trusted_domains "$td_idx" --value="$trusted_domain" >/dev/null
    fi
  done

  # SCIM token: read or create twinbox/global/nextcloud-scim in OpenBao.
  existing_scim_token="$(openbao_read_global_secret_json nextcloud-scim 2>/dev/null | jq -r '.NEXTCLOUD_SCIM_TOKEN // empty' || true)"
  if [[ -n "$existing_scim_token" ]]; then
    scim_token="$existing_scim_token"
    log "Reusing NEXTCLOUD_SCIM_TOKEN from OpenBao twinbox/global/nextcloud-scim"
  else
    scim_token="$(openssl rand -hex 48)"
    (
      local scim_token_file
      scim_token_file="$(mktemp)"
      trap 'rm -f "$scim_token_file"' EXIT
      jq -n --arg token "$scim_token" '{NEXTCLOUD_SCIM_TOKEN: $token}' >"$scim_token_file"
      bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
        --secret-name "nextcloud-scim" \
        --json-file "$scim_token_file" \
        --required-keys "NEXTCLOUD_SCIM_TOKEN"
    )
    log "Generated NEW NEXTCLOUD_SCIM_TOKEN -> OpenBao twinbox/global/nextcloud-scim"
  fi

  # Set the scim_sp token in Nextcloud (idempotent).
  printf '%s' "$scim_token" | kubectl exec -i -n nextcloud "$pod" -c nextcloud -- \
    php /var/www/html/occ scim_sp:token:set authentik --token-stdin >/dev/null
  log "scim_sp token 'authentik' set in Nextcloud"

  # Default SCIM property mappings (by name).
  user_mapping_pk="$(authentik_api_get "/propertymappings/provider/scim/?page_size=100" | jq -r --arg n 'authentik default SCIM Mapping: User' '.results | map(select(.name == $n)) | .[0].pk // empty')"
  group_mapping_pk="$(authentik_api_get "/propertymappings/provider/scim/?page_size=100" | jq -r --arg n 'authentik default SCIM Mapping: Group' '.results | map(select(.name == $n)) | .[0].pk // empty')"
  [[ -n "$user_mapping_pk" ]] || fail "Default SCIM User property mapping not found by name"
  [[ -n "$group_mapping_pk" ]] || fail "Default SCIM Group property mapping not found by name"

  # Create or reconcile the "Nextcloud SCIM" provider.
  local provider_json provider_pk app_json app_pk app_primary final_bc sync_baseline
  provider_json="$(
    jq -c -n \
      --arg name "Nextcloud SCIM" \
      --arg url "$scim_url" \
      --arg token "$scim_token" \
      --arg um "$user_mapping_pk" \
      --arg gm "$group_mapping_pk" \
      '{name: $name, url: $url, token: $token, compatibility_mode: "default", exclude_users_service_account: true, property_mappings: [$um], property_mappings_group: [$gm]}'
  )"
  provider_pk="$(authentik_api_get "/providers/scim/?page_size=100" | jq -r --arg n 'Nextcloud SCIM' '.results | map(select(.name == $n)) | .[0].pk // empty')"
  if [[ -z "$provider_pk" ]]; then
    provider_pk="$(authentik_api_write POST "/providers/scim/" "$provider_json" | jq -r '.pk')"
    log "Created Authentik SCIM provider 'Nextcloud SCIM' (pk $provider_pk)"
  else
    authentik_api_write PATCH "/providers/scim/${provider_pk}/" "$provider_json" >/dev/null
    log "Reconciled Authentik SCIM provider 'Nextcloud SCIM' (pk $provider_pk)"
  fi

  # Bind as backchannel on the nextcloud application, preserving the OIDC primary.
  app_json="$(authentik_api_get "/core/applications/nextcloud/")"
  app_pk="$(jq -r '.pk' <<<"$app_json")"
  app_primary="$(jq -r '.provider' <<<"$app_json")"
  if jq -e --argjson pk "$provider_pk" '.backchannel_providers | index($pk)' <<<"$app_json" >/dev/null 2>&1; then
    log "SCIM provider $provider_pk already bound as backchannel on application $app_pk"
  else
    final_bc="$(jq -c --argjson add "$provider_pk" '.backchannel_providers + [$add] | unique' <<<"$app_json")"
    authentik_api_write PATCH "/core/applications/${app_pk}/" "{\"backchannel_providers\": ${final_bc}}" >/dev/null
    log "Bound SCIM provider $provider_pk as backchannel on application $app_pk (primary provider $app_primary untouched)"
  fi

  # admins -> admin group map (protected break-glass 'admin' is never removed).
  kubectl exec -n nextcloud "$pod" -c nextcloud -- \
    php /var/www/html/occ scim_sp:group-map:set admins admin --allow-protected >/dev/null
  log "SCIM group-map set: admins -> admin (allow-protected)"

  # Trigger a full sync and wait for confirmation.
  sync_baseline="$(authentik_api_get "/providers/scim/${provider_pk}/sync/status/" | jq -r '.last_successful_sync // "none"')"
  log "Triggering SCIM sync (baseline last_successful_sync=$sync_baseline)"
  if ! timeout 90 kubectl exec -n authentik deploy/authentik-worker -- ak scim_sync "Nextcloud SCIM" >/dev/null 2>&1; then
    # Current Authentik releases enqueue the task successfully but can exit 1
    # afterwards when the CLI result backend raises ResultMissing. The status
    # endpoint below is the authoritative completion check.
    log "SCIM sync command returned before a result was available; waiting for provider status"
  fi
  for _ in $(seq 1 45); do
    local sync_status sync_last
    sync_status="$(authentik_api_get "/providers/scim/${provider_pk}/sync/status/" 2>/dev/null || true)"
    sync_last="$(jq -r '.last_successful_sync // "none"' <<<"$sync_status" 2>/dev/null || echo none)"
    if [[ "$sync_last" != "none" && "$sync_last" != "$sync_baseline" ]]; then
      log "SCIM sync completed: last_successful_sync=$sync_last"
      return 0
    fi
    sleep 2
  done
  fail "SCIM sync not confirmed complete within 90s"
}

nextcloud_user_exists() {
  local username="$1"
  kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
    "cd /var/www/html && php occ user:info $(printf '%q' "$username") >/dev/null 2>&1"
}

nextcloud_user_id_for_mail_account() {
  local username="$1"
  local email="$2"
  local users_json candidate candidate_email

  if [[ -n "$username" ]] && nextcloud_user_exists "$username"; then
    printf '%s\n' "$username"
    return 0
  fi

  users_json="$(nextcloud_occ "user:list --output=json" 2>/dev/null || true)"
  if [[ -z "$users_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$users_json"; then
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    candidate_email="$(
      nextcloud_occ "user:info $(printf '%q' "$candidate") --output=json" 2>/dev/null |
        jq -r '.email // empty' || true
    )"
    if [[ "${candidate_email,,}" == "${email,,}" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(jq -r 'keys[]' <<<"$users_json")
}

nextcloud_mail_account_exists() {
  local user_id="$1"
  local email="$2"
  kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
    "cd /var/www/html && php occ mail:account:export $(printf '%q' "$user_id") 2>/dev/null | grep -F -- $(printf '%q' "$email") >/dev/null"
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
    local email username name nextcloud_user_id mail_token
    email="$(jq -r '.email' <<<"$user_entry")"
    username="$(jq -r '.username // empty' <<<"$user_entry")"
    name="$(jq -r '.name // .username // .email' <<<"$user_entry")"

    if [[ -z "$username" || "$email" != *@${mail_domain} ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    nextcloud_user_id="$(nextcloud_user_id_for_mail_account "$username" "$email")"
    if [[ -z "$nextcloud_user_id" ]]; then
      log "  SKIP ${email}: Nextcloud user with this email does not exist yet"
      skipped=$((skipped + 1))
      continue
    fi

    if nextcloud_mail_account_exists "$nextcloud_user_id" "$email"; then
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
      "cd /var/www/html && php occ mail:account:create $(printf '%q' "$nextcloud_user_id") $(printf '%q' "$name") $(printf '%q' "$email") $(printf '%q' "$imap_hostname") $(printf '%q' "$imap_port") $(printf '%q' "$imap_security") $(printf '%q' "$email") $(printf '%q' "$mail_token") $(printf '%q' "$smtp_hostname") $(printf '%q' "$smtp_port") $(printf '%q' "$smtp_security") $(printf '%q' "$email") $(printf '%q' "$mail_token") password >/dev/null"; then
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

if [[ -n "$existing_nextcloud_secret_json" ]]; then
  nextcloud_admin_username="$(jq -r '.NEXTCLOUD_ADMIN_USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_admin_password="$(jq -r '.NEXTCLOUD_ADMIN_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_db_username="$(jq -r '.NEXTCLOUD_POSTGRESQL__USERNAME // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_db_password="$(jq -r '.NEXTCLOUD_POSTGRESQL__PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_redis_password="$(jq -r '.NEXTCLOUD_REDIS_PASSWORD // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_oidc_client_id="$(jq -r '.NEXTCLOUD_OIDC_CLIENT_ID // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_oidc_client_secret="$(jq -r '.NEXTCLOUD_OIDC_CLIENT_SECRET // empty' <<<"$existing_nextcloud_secret_json" || true)"
  nextcloud_eurooffice_jwt_secret="$(jq -r '.EUROOFFICE_JWT_SECRET // empty' <<<"$existing_nextcloud_secret_json" || true)"
fi

[[ -n "$nextcloud_admin_username" ]] || nextcloud_admin_username="admin"
[[ -n "$nextcloud_admin_password" ]] || nextcloud_admin_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_db_username" ]] || nextcloud_db_username="nextcloud"
[[ -n "$nextcloud_db_password" ]] || nextcloud_db_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_redis_password" ]] || nextcloud_redis_password="$(openssl rand -hex 24)"
[[ -n "$nextcloud_oidc_client_id" ]] || nextcloud_oidc_client_id="$(openssl rand -hex 16)"
[[ -n "$nextcloud_oidc_client_secret" ]] || nextcloud_oidc_client_secret="$(openssl rand -hex 32)"
[[ -n "$nextcloud_eurooffice_jwt_secret" ]] || nextcloud_eurooffice_jwt_secret="$(openssl rand -hex 32)"

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
  '{
    "NEXTCLOUD_ADMIN_USERNAME": $nextcloud_admin_username,
    "NEXTCLOUD_ADMIN_PASSWORD": $nextcloud_admin_password,
    "NEXTCLOUD_POSTGRESQL__USERNAME": $nextcloud_postgresql_username,
    "NEXTCLOUD_POSTGRESQL__PASSWORD": $nextcloud_postgresql_password,
    "NEXTCLOUD_REDIS_PASSWORD": $nextcloud_redis_password,
    "NEXTCLOUD_OIDC_CLIENT_ID": $nextcloud_oidc_client_id,
    "NEXTCLOUD_OIDC_CLIENT_SECRET": $nextcloud_oidc_client_secret,
    "EUROOFFICE_JWT_SECRET": $eurooffice_jwt_secret
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
nextcloud_groups = list(groups)
if ak_is_group_member(request.user, name="admins") and "admin" not in nextcloud_groups:
    nextcloud_groups.append("admin")
if request.user.is_superuser and "admin" not in nextcloud_groups:
    nextcloud_groups.append("admin")
return {
    "groups": groups,
    "nextcloud_groups": nextcloud_groups,
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

log "Syncing Nextcloud bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "nextcloud" \
  --json-file "$nextcloud_secret_file" \
  --required-keys "NEXTCLOUD_ADMIN_USERNAME,NEXTCLOUD_ADMIN_PASSWORD,NEXTCLOUD_POSTGRESQL__USERNAME,NEXTCLOUD_POSTGRESQL__PASSWORD,NEXTCLOUD_REDIS_PASSWORD,NEXTCLOUD_OIDC_CLIENT_ID,NEXTCLOUD_OIDC_CLIENT_SECRET,EUROOFFICE_JWT_SECRET"
log "Applying Nextcloud Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/optional-apps/nextcloud.yaml" \
  --application "nextcloud"

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
    --mapping-groups='nextcloud_groups' \
    --group-provisioning='0' \
    --group-restrict-login-to-whitelist='0' \
    --unique-uid='1' \
    --check-bearer='0' \
    --bearer-provisioning='0' \
    --send-id-token-hint='1' \
    --resolve-nested-claims='1'
  php occ config:app:set --type=string --value=0 user_oidc provider-1-groupProvisioning
  php occ app:disable oidc_groups_mapping >/dev/null 2>&1 || true
"

install_nextcloud_scim

log "Provisioning SCIM group ownership (scim_sp)"
# SCIM (scim_sp) is the single writer for Nextcloud groups from now on.
provision_nextcloud_scim

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

log "Installing Twinbox Mail provisioning app"
tar -C "$WORKSPACE_ROOT/categories/apps/steps/install-nextcloud" -cf - twinbox-mail-provisioning \
  | kubectl exec -i -n nextcloud deploy/nextcloud -c nextcloud -- sh -lc '
    set -eu
    cd /var/www/html/custom_apps
    rm -rf twinbox_mail_provisioning
    tar -xf -
    mv twinbox-mail-provisioning twinbox_mail_provisioning
    chown -R www-data:www-data twinbox_mail_provisioning
  '
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- su -s /bin/bash www-data -c \
  "php occ app:enable twinbox_mail_provisioning >/dev/null"

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
