#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
LOGIN_SECRET_FILE="$BOOTSTRAP_ROOT/secrets/global/twinbox-login.json"
AUTHENTIK_LOCAL_FORWARD_PORT="${AUTHENTIK_LOCAL_FORWARD_PORT:-18299}"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

json_list_items() {
  jq -c '
    if type == "array" then
      .
    elif has("results") then
      .results
    elif has("items") then
      .items
    elif has("data") then
      .data
    else
      []
    end
  '
}

authentik_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response_file
  local status

  response_file="$(mktemp)"

  if [[ -n "$data" ]]; then
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "$data" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${AUTHENTIK_API_BASE}${path}"
    )" || {
      rm -f "$response_file"
      fail "Authentik API request failed: ${method} ${path}"
    }
  else
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${AUTHENTIK_API_BASE}${path}"
    )" || {
      rm -f "$response_file"
      fail "Authentik API request failed: ${method} ${path}"
    }
  fi

  local body
  body="$(cat "$response_file")"
  rm -f "$response_file"

  if [[ ! "$status" =~ ^2 ]]; then
    if [[ -n "$body" ]]; then
      fail "Authentik API ${method} ${path} failed with HTTP ${status}: ${body}"
    fi
    fail "Authentik API ${method} ${path} failed with HTTP ${status}"
  fi

  printf '%s' "$body"
}

authentik_wait_for_local_forward() {
  local forward_port="$1"
  local forward_pid="$2"
  local forward_log="$3"
  local attempt=1
  local attempts=60

  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsS "http://127.0.0.1:${forward_port}/-/health/live/" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$forward_pid" >/dev/null 2>&1; then
      if [[ -s "$forward_log" ]]; then
        log "Authentik port-forward exited early; last log lines:"
        tail -n 20 "$forward_log" >&2
      fi
      fail "Authentik port-forward on 127.0.0.1:${forward_port} exited before it became ready"
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  if [[ -s "$forward_log" ]]; then
    log "Authentik port-forward log:"
    tail -n 20 "$forward_log" >&2
  fi

  fail "Authentik port-forward on 127.0.0.1:${forward_port} did not become ready"
}

authentik_find_user() {
  local username="$1"
  local payload

  payload="$(authentik_request GET "/core/users/?page_size=100")"
  printf '%s' "$payload" | json_list_items | jq -c --arg username "$username" '
    map(select((.username // "") == $username))
    | .[0] // empty
  '
}

authentik_find_group() {
  local group_name="$1"
  local payload

  payload="$(authentik_request GET "/core/groups/?page_size=100")"
  printf '%s' "$payload" | json_list_items | jq -c --arg group_name "$group_name" '
    map(select((.name // "") == $group_name))
    | .[0] // empty
  '
}

authentik_upsert_user() {
  local username="$1"
  local full_name="$2"
  local email="$3"
  local user_json=""
  local user_id=""
  local create_payload=""
  local update_payload=""

  user_json="$(authentik_find_user "$username" || true)"

  if [[ -z "$user_json" ]]; then
    create_payload="$(jq -n \
      --arg username "$username" \
      --arg full_name "$full_name" \
      --arg email "$email" \
      '{
        username: $username,
        name: $full_name
      }
      + (if $email != "" then {email: $email} else {} end)'
    )"
    user_json="$(authentik_request POST "/core/users/" "$create_payload")"
  fi

  user_id="$(printf '%s' "$user_json" | jq -r '.pk // .id // .uuid // empty')"
  [[ -n "$user_id" ]] || fail "Could not determine Authentik user ID for ${username}"

  update_payload="$(jq -n \
    --arg full_name "$full_name" \
    --arg email "$email" \
    '{
      name: $full_name
    }
    + (if $email != "" then {email: $email} else {} end)'
  )"
  authentik_request PATCH "/core/users/${user_id}/" "$update_payload" >/dev/null

  authentik_request POST "/core/users/${user_id}/set_password/" "$(jq -n --arg password "$LOGIN_PASSWORD" '{password: $password}')" >/dev/null

  printf '%s' "$user_id"
}

authentik_upsert_admin_group() {
  local group_name="$1"
  local group_json=""
  local group_id=""
  local group_payload=""

  group_json="$(authentik_find_group "$group_name" || true)"

  if [[ -z "$group_json" ]]; then
    group_payload="$(jq -n --arg name "$group_name" '{name: $name, is_superuser: true}')"
    group_json="$(authentik_request POST "/core/groups/" "$group_payload")"
  else
    group_payload="$(jq -n --arg name "$group_name" '{name: $name, is_superuser: true}')"
    group_id="$(printf '%s' "$group_json" | jq -r '.pk // .id // .uuid // empty')"
    [[ -n "$group_id" ]] || fail "Could not determine Authentik group ID for ${group_name}"
    authentik_request PATCH "/core/groups/${group_id}/" "$group_payload" >/dev/null
    group_json="$(authentik_request GET "/core/groups/${group_id}/")"
  fi

  group_id="$(printf '%s' "$group_json" | jq -r '.pk // .id // .uuid // empty')"
  [[ -n "$group_id" ]] || fail "Could not determine Authentik group ID for ${group_name}"

  printf '%s' "$group_json"
}

authentik_group_has_user() {
  local group_json="$1"
  local user_id="$2"

  printf '%s' "$group_json" | jq -e --arg user_id "$user_id" '
    (
      if (.users // null) != null then
        (.users | map(tostring))
      elif (.users_obj // null) != null then
        (.users_obj | map((.pk // .id // .uuid // empty) | tostring))
      else
        []
      end
    ) | index($user_id) != null
  ' >/dev/null
}

authentik_add_user_to_group() {
  local group_id="$1"
  local user_id="$2"

  authentik_request POST "/core/groups/${group_id}/add_user/" "$(jq -n --arg user_id "$user_id" '{pk: $user_id}')" >/dev/null
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -f "$LOGIN_SECRET_FILE" ]] || fail "Wizard login secret not found at $LOGIN_SECRET_FILE"

authentik_secret_json="$(openbao_read_global_secret_json authentik)"
AUTHENTIK_TOKEN="$(jq -r '.AUTHENTIK_BOOTSTRAP_TOKEN // empty' <<<"$authentik_secret_json")"
LOGIN_PASSWORD="$(jq -r '.password // .PASSWORD // empty' "$LOGIN_SECRET_FILE")"

[[ -n "$AUTHENTIK_TOKEN" ]] || fail "Could not read AUTHENTIK_BOOTSTRAP_TOKEN from OpenBao"
[[ -n "$LOGIN_PASSWORD" ]] || fail "Could not read password from $LOGIN_SECRET_FILE"

AUTHENTIK_API_BASE="http://127.0.0.1:${AUTHENTIK_LOCAL_FORWARD_PORT}/api/v3"
FULL_NAME="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.full_name // empty')"
USERNAME="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.username // empty')"
EMAIL="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.email // empty')"
ADMIN_GROUP_NAME="admins"

[[ -n "$FULL_NAME" ]] || fail "full_name is required"
[[ -n "$USERNAME" ]] || fail "username is required"

forward_log="$(mktemp "${TMPDIR:-/tmp}/authentik-port-forward.XXXXXX.log")"
port_forward_pid=""

cleanup_port_forward() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$forward_log"
}

trap cleanup_port_forward EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl -n authentik port-forward "svc/authentik-server" "${AUTHENTIK_LOCAL_FORWARD_PORT}:80" >"$forward_log" 2>&1 &
port_forward_pid="$!"
authentik_wait_for_local_forward "$AUTHENTIK_LOCAL_FORWARD_PORT" "$port_forward_pid" "$forward_log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating Authentik user ${USERNAME}"
USER_ID="$(authentik_upsert_user "$USERNAME" "$FULL_NAME" "$EMAIL")"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring Authentik group ${ADMIN_GROUP_NAME}"
GROUP_JSON="$(authentik_upsert_admin_group "$ADMIN_GROUP_NAME")"
GROUP_ID="$(printf '%s' "$GROUP_JSON" | jq -r '.pk // .id // .uuid // empty')"
[[ -n "$GROUP_ID" ]] || fail "Could not determine Authentik group ID for ${ADMIN_GROUP_NAME}"

if ! authentik_group_has_user "$GROUP_JSON" "$USER_ID"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Adding ${USERNAME} to ${ADMIN_GROUP_NAME}"
  authentik_add_user_to_group "$GROUP_ID" "$USER_ID"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg full_name "$FULL_NAME" \
    --arg username "$USERNAME" \
    --arg email "$EMAIL" \
    --arg group_name "$ADMIN_GROUP_NAME" \
    --arg user_id "$USER_ID" \
    --arg group_id "$GROUP_ID" \
    '{
      cluster_id: $cluster_id,
      full_name: $full_name,
      username: $username,
      email: $email,
      group_name: $group_name,
      user_id: $user_id,
      group_id: $group_id
    }' >"$STEP_RESULT_FILE"
fi
