#!/usr/bin/env bash
# Shared Authentik authentication helper.
# Sources openbao-secret-sync.sh prerequisite.
#
# The twinbox-automation service account and API token are created declaratively
# by an Authentik blueprint (gitops/platform/authentik/blueprint-twinbox-automation.yaml).
# The blueprint runs during Authentik worker reconciliation and sets the token key
# from the AUTHENTIK_AUTOMATION_TOKEN env var (mounted via worker secret).
#
# Usage:
#   source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
#   authentik_ensure_token
#   echo "$AUTHENTIK_TOKEN"        # usable for API calls or OpenTofu AUTHENTIK_TOKEN env
#   echo "$AUTHENTIK_API_BASE"     # base URL for API calls (if forward set up)

set -euo pipefail

AUTHENTIK_AUTH_LOG_PREFIX="${AUTHENTIK_AUTH_LOG_PREFIX:-Authentik}"

_authentik_log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${AUTHENTIK_AUTH_LOG_PREFIX}: $*"
}

_authentik_fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${AUTHENTIK_AUTH_LOG_PREFIX} ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Populate AUTHENTIK_TOKEN for API calls.
# Always reads the persistent token from OpenBao first.
# AUTHENTIK_AUTOMATION_TOKEN may be set as an env var by worker-side secret
# mounts in container-run contexts.
# ---------------------------------------------------------------------------
authentik_ensure_token() {
  if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
    local secret_json
    secret_json="$(openbao_read_global_secret_json authentik)"
    AUTHENTIK_API_TOKEN="$(jq -r '.AUTHENTIK_API_TOKEN // empty' <<<"$secret_json")"
  fi

  if [[ -n "${AUTHENTIK_API_TOKEN:-}" ]]; then
    _authentik_log "Using persistent API token from OpenBao"
    AUTHENTIK_TOKEN="$AUTHENTIK_API_TOKEN"
  elif [[ -n "${AUTHENTIK_AUTOMATION_TOKEN:-}" ]]; then
    _authentik_log "Using automation token from worker secret"
    AUTHENTIK_TOKEN="$AUTHENTIK_AUTOMATION_TOKEN"
  else
    _authentik_fail "No Authentik API token available – AUTHENTIK_API_TOKEN or AUTHENTIK_AUTOMATION_TOKEN must be set"
  fi
}

# ---------------------------------------------------------------------------
# Verify the blueprint-created service account and token exist, and persist
# the token to OpenBao as AUTHENTIK_API_TOKEN.
# ---------------------------------------------------------------------------
AUTHENTIK_SA_NAME="${AUTHENTIK_SA_NAME:-twinbox-automation}"
AUTHENTIK_SA_TOKEN_IDENTIFIER="${AUTHENTIK_SA_TOKEN_IDENTIFIER:-twinbox-automation-api-token}"
AUTHENTIK_SIGNING_KEY_NAME="${AUTHENTIK_SIGNING_KEY_NAME:-authentik Self-signed Certificate}"
AUTHENTIK_DEFAULT_PROVIDER_AUTHORIZATION_FLOW_SLUG="${AUTHENTIK_DEFAULT_PROVIDER_AUTHORIZATION_FLOW_SLUG:-default-provider-authorization-implicit-consent}"
AUTHENTIK_DEFAULT_PROVIDER_INVALIDATION_FLOW_SLUG="${AUTHENTIK_DEFAULT_PROVIDER_INVALIDATION_FLOW_SLUG:-default-provider-invalidation-flow}"

authentik_create_service_account_token() {
  if [[ -n "${AUTHENTIK_API_TOKEN:-}" ]]; then
    _authentik_log "Persistent API token already exists in OpenBao – skipping"
    return 0
  fi

  if [[ -z "${AUTHENTIK_AUTOMATION_TOKEN:-}" ]]; then
    _authentik_fail "AUTHENTIK_AUTOMATION_TOKEN is not set – the worker secret must be mounted as envFrom"
  fi

  _authentik_log "Verifying blueprint-created service account '${AUTHENTIK_SA_NAME}' exists"

  # --- Verify service account exists ---
  local sa_json
  sa_json="$(curl -sS \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${AUTHENTIK_AUTOMATION_TOKEN}" \
    "${AUTHENTIK_API_BASE}/core/users/?type=service_account&search=${AUTHENTIK_SA_NAME}" \
  )" || _authentik_fail "Failed to query service accounts"

  local sa_pk
  sa_pk="$(printf '%s' "$sa_json" | jq -r '
    (.results // [])
    | map(select(.username == $name))
    | .[0].pk // empty
  ' --arg name "$AUTHENTIK_SA_NAME")"

  if [[ -z "$sa_pk" ]]; then
    _authentik_fail "Blueprint service account '${AUTHENTIK_SA_NAME}' not found – blueprint may not have been applied yet"
  fi

  _authentik_log "Blueprint service account '${AUTHENTIK_SA_NAME}' confirmed (pk=${sa_pk})"

  # --- Verify token object exists ---
  local token_json
  token_json="$(curl -sS \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${AUTHENTIK_AUTOMATION_TOKEN}" \
    "${AUTHENTIK_API_BASE}/core/tokens/?identifier=${AUTHENTIK_SA_TOKEN_IDENTIFIER}" \
  )" || _authentik_fail "Failed to query tokens"

  local token_exists
  token_exists="$(printf '%s' "$token_json" | jq -r '
    (.results // [])
    | map(select(.identifier == $id))
    | length > 0
  ' --arg id "$AUTHENTIK_SA_TOKEN_IDENTIFIER")"

  if [[ "$token_exists" != "true" ]]; then
    _authentik_fail "Blueprint token '${AUTHENTIK_SA_TOKEN_IDENTIFIER}' not found – blueprint may not have been applied yet"
  fi

  _authentik_log "Blueprint token '${AUTHENTIK_SA_TOKEN_IDENTIFIER}' confirmed"

  # --- Persist the token key in OpenBao ---
  if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
    local current_secret
    current_secret="$(openbao_read_global_secret_json authentik)"
    local updated_secret
    updated_secret="$(printf '%s' "$current_secret" | jq \
      --arg api_token "$AUTHENTIK_AUTOMATION_TOKEN" \
      '. + {AUTHENTIK_API_TOKEN: $api_token}' \
    )"

    local tmp_file
    tmp_file="$(mktemp)"
    printf '%s' "$updated_secret" >"$tmp_file"

    _authentik_log "Persisting AUTHENTIK_API_TOKEN in OpenBao"
    bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
      --secret-name "authentik" \
      --json-file "$tmp_file" \
      --required-keys "AUTHENTIK_API_TOKEN"

    rm -f "$tmp_file"
  fi

  AUTHENTIK_API_TOKEN="$AUTHENTIK_AUTOMATION_TOKEN"
  AUTHENTIK_TOKEN="$AUTHENTIK_AUTOMATION_TOKEN"

  _authentik_log "Service account token verified and persisted"
}

# ---------------------------------------------------------------------------
# Set up a kubectl port-forward to Authentik and populate AUTHENTIK_API_BASE
# ---------------------------------------------------------------------------
AUTHENTIK_FORWARD_PID=""
AUTHENTIK_FORWARD_LOG=""
AUTHENTIK_FORWARD_PORT=""

_authentik_port_in_use() {
  local port="$1"

  if [[ -r /proc/net/tcp ]]; then
    local port_hex
    port_hex="$(printf '%04X' "$port")"
    awk -v port_hex="$port_hex" '
      NR > 1 {
        split($2, address, ":")
        if (toupper(address[2]) == port_hex) {
          found = 1
        }
      }
      END {
        exit found ? 0 : 1
      }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
    return $?
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk -v port=":${port}" '
      $4 == port || $4 ~ port "$" {
        found = 1
      }
      END {
        exit found ? 0 : 1
      }
    '
    return $?
  fi

  (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

_authentik_pick_forward_port() {
  local attempt=1
  local candidate

  while [[ "$attempt" -le 200 ]]; do
    candidate=$((20000 + RANDOM % 30000))
    if ! _authentik_port_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    attempt=$((attempt + 1))
  done

  _authentik_fail "Could not find a free local port for Authentik port-forward"
}

authentik_setup_forward() {
  authentik_teardown_forward

  local requested_port="${AUTHENTIK_LOCAL_FORWARD_PORT:-}"
  local port="$requested_port"

  if [[ -z "$port" ]]; then
    port="$(_authentik_pick_forward_port)"
  fi

  AUTHENTIK_FORWARD_LOG="$(mktemp "${TMPDIR:-/tmp}/authentik-port-forward.XXXXXX.log")"
  kubectl -n authentik port-forward "svc/authentik-server" "${port}:80" >"$AUTHENTIK_FORWARD_LOG" 2>&1 &
  AUTHENTIK_FORWARD_PID="$!"

  local attempt=1
  local attempts=60
  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsS "http://127.0.0.1:${port}/-/health/live/" >/dev/null 2>&1; then
      AUTHENTIK_API_BASE="http://127.0.0.1:${port}/api/v3"
      AUTHENTIK_FORWARD_PORT="$port"
      return 0
    fi
    if ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
      if [[ -s "$AUTHENTIK_FORWARD_LOG" ]]; then
        tail -n 20 "$AUTHENTIK_FORWARD_LOG" >&2
      fi
      if [[ -n "$requested_port" ]]; then
        _authentik_fail "Authentik port-forward on 127.0.0.1:${requested_port} exited before ready"
      fi
      _authentik_fail "Authentik port-forward exited before ready"
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  if [[ -s "$AUTHENTIK_FORWARD_LOG" ]]; then
    tail -n 20 "$AUTHENTIK_FORWARD_LOG" >&2
  fi
  if [[ -n "$requested_port" ]]; then
    _authentik_fail "Authentik port-forward on 127.0.0.1:${requested_port} did not become ready"
  fi
  _authentik_fail "Authentik port-forward on 127.0.0.1:${port} did not become ready"
}

authentik_api_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response_file
  local status
  local body
  local attempt=1
  local max_attempts=5
  local retry_delay=1
  local auth_headers=(-H "Accept: application/json")

  [[ -n "${AUTHENTIK_API_BASE:-}" ]] || _authentik_fail "AUTHENTIK_API_BASE is not set; call authentik_setup_forward first"
  [[ -n "${AUTHENTIK_TOKEN:-}" ]] || _authentik_fail "AUTHENTIK_TOKEN is not set; call authentik_ensure_token first"

  if [[ "${AUTHENTIK_USE_COOKIE:-false}" == "true" ]]; then
    auth_headers+=(-H "Cookie: ${AUTHENTIK_TOKEN}")
  else
    auth_headers+=(-H "Authorization: Bearer ${AUTHENTIK_TOKEN}")
  fi

  while true; do
    response_file="$(mktemp)"

    if [[ -n "$data" ]]; then
      auth_headers_with_content=("${auth_headers[@]}" -H "Content-Type: application/json")
      status="$(
        curl -sS \
          -X "$method" \
          "${auth_headers_with_content[@]}" \
          --data-binary "$data" \
          -o "$response_file" \
          -w '%{http_code}' \
          "${AUTHENTIK_API_BASE}${path}"
      )" || status="000"
    else
      status="$(
        curl -sS \
          -X "$method" \
          "${auth_headers[@]}" \
          -o "$response_file" \
          -w '%{http_code}' \
          "${AUTHENTIK_API_BASE}${path}"
      )" || status="000"
    fi

    body="$(cat "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"

    if [[ "$status" =~ ^2 ]]; then
      printf '%s' "$body"
      return 0
    fi

    if [[ "$status" == "000" || "$status" =~ ^5 ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]] && ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
          _authentik_log "Authentik port-forward died while calling ${method} ${path}; re-establishing"
          authentik_setup_forward
        fi
        _authentik_log "Retrying ${method} ${path} after transient HTTP ${status}"
        sleep "$retry_delay"
        attempt=$((attempt + 1))
        retry_delay=$((retry_delay * 2))
        continue
      fi
    fi

    if [[ -n "$body" ]]; then
      _authentik_fail "Authentik API ${method} ${path} failed with HTTP ${status}: ${body}"
    fi
    _authentik_fail "Authentik API ${method} ${path} failed with HTTP ${status}"
  done
}

authentik_api_get() {
  authentik_api_request GET "$1"
}

authentik_api_write() {
  authentik_api_request "$1" "$2" "$3"
}

_authentik_create_flow_if_missing() {
  local flow_slug="$1"
  local flow_name="$2"
  local flow_title="$3"
  local flow_designation="$4"
  local flow_authentication="$5"
  local flow_policy_engine_mode="$6"
  local flow_compatible_providers="$7"
  local existing

  existing="$(authentik_api_get "/flows/instances/?slug=${flow_slug}&page_size=100")" || return 1
  if jq -e '.results | length > 0' >/dev/null 2>&1 <<<"$existing"; then
    return 0
  fi

  _authentik_log "Creating flow '${flow_slug}'"
  authentik_api_write POST "/flows/instances/" "$(
    jq -n \
      --arg name "$flow_name" \
      --arg slug "$flow_slug" \
      --arg title "$flow_title" \
      --arg designation "$flow_designation" \
      --arg authentication "$flow_authentication" \
      --arg policy_engine_mode "$flow_policy_engine_mode" \
      --argjson compatible_providers "$flow_compatible_providers" \
      '{
        name: $name,
        slug: $slug,
        title: $title,
        designation: $designation,
        authentication: $authentication,
        policy_engine_mode: $policy_engine_mode,
        compatible_providers: $compatible_providers
      }'
  )" >/dev/null
}

authentik_ensure_default_provider_flows() {
  _authentik_create_flow_if_missing \
    "$AUTHENTIK_DEFAULT_PROVIDER_AUTHORIZATION_FLOW_SLUG" \
    "Default Provider Authorization Implicit Consent" \
    "Default Provider Authorization Implicit Consent" \
    "authorization" \
    "require_authenticated" \
    "any" \
    "[1, 2]"

  _authentik_create_flow_if_missing \
    "$AUTHENTIK_DEFAULT_PROVIDER_INVALIDATION_FLOW_SLUG" \
    "Default Provider Invalidation Flow" \
    "Default Provider Invalidation Flow" \
    "invalidation" \
    "require_authenticated" \
    "any" \
    "[]"
}

authentik_resolve_flow_id() {
  local slug="$1"
  local designation="$2"
  local response match_pk

  response="$(authentik_api_get "/flows/instances/?slug=${slug}&page_size=100")" || return 1
  match_pk="$(
    jq -r \
      --arg slug "$slug" \
      --arg designation "$designation" \
      '.results[]?
        | select((.slug // "") == $slug and (.designation // "") == $designation)
        | .pk // .id // empty' <<<"$response" | head -n1
  )"
  if [[ -n "$match_pk" ]]; then
    printf '%s\n' "$match_pk"
    return 0
  fi

  case "$slug" in
    "$AUTHENTIK_DEFAULT_PROVIDER_AUTHORIZATION_FLOW_SLUG" | "$AUTHENTIK_DEFAULT_PROVIDER_INVALIDATION_FLOW_SLUG")
      authentik_ensure_default_provider_flows || return 1
      response="$(authentik_api_get "/flows/instances/?slug=${slug}&page_size=100")" || return 1
      match_pk="$(
        jq -r \
          --arg slug "$slug" \
          --arg designation "$designation" \
          '.results[]?
            | select((.slug // "") == $slug and (.designation // "") == $designation)
            | .pk // .id // empty' <<<"$response" | head -n1
      )"
      if [[ -n "$match_pk" ]]; then
        printf '%s\n' "$match_pk"
        return 0
      fi
      ;;
  esac

  return 1
}

authentik_resolve_scope_mapping_id() {
  local scope_name="$1"
  local response managed_pk fallback_pk

  response="$(authentik_api_get "/propertymappings/provider/scope/?scope_name=${scope_name}&page_size=20")" || return 1
  managed_pk="$(
    jq -r \
      --arg scope_name "$scope_name" \
      '.results[]?
        | select((.scope_name // "") == $scope_name and ((.managed // "") | length > 0))
        | .pk // empty' <<<"$response" | head -n1
  )"
  if [[ -n "$managed_pk" ]]; then
    printf '%s\n' "$managed_pk"
    return 0
  fi

  fallback_pk="$(
    jq -r \
      --arg scope_name "$scope_name" \
      '.results[]?
        | select((.scope_name // "") == $scope_name)
        | .pk // empty' <<<"$response" | head -n1
  )"
  printf '%s\n' "$fallback_pk"
}

authentik_resolve_signing_key_id() {
  local signing_key_name="${1:-$AUTHENTIK_SIGNING_KEY_NAME}"
  local response

  response="$(authentik_api_get "/crypto/certificatekeypairs/?page_size=200")" || return 1
  jq -r \
    --arg name "$signing_key_name" \
    '.results[]?
      | select((.name // "") == $name)
      | .pk // .id // .uuid // empty' <<<"$response" | head -n1
}

authentik_find_group_id() {
  local group_name="$1"
  local response

  response="$(authentik_api_get "/core/groups/?page_size=200")" || return 1
  jq -r \
    --arg group_name "$group_name" \
    '.results[]?
      | select((.name // "") == $group_name)
      | .pk // .id // .uuid // empty' <<<"$response" | head -n1
}

authentik_teardown_forward() {
  if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]]; then
    kill "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  rm -f "${AUTHENTIK_FORWARD_LOG:-}"
  AUTHENTIK_FORWARD_PID=""
  AUTHENTIK_FORWARD_LOG=""
  AUTHENTIK_FORWARD_PORT=""
}

if [[ -z "${_AUTHENTIK_FORWARD_TRAP_SET:-}" ]]; then
  trap 'authentik_teardown_forward' EXIT
  _AUTHENTIK_FORWARD_TRAP_SET=1
fi
