#!/usr/bin/env bash
# Shared Authentik authentication helper.
# Sources openbao-secret-sync.sh prerequisite.
#
# Usage:
#   source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
#   authentik_ensure_token
#   echo "$AUTHENTIK_TOKEN"        # usable for API calls or OpenTofu AUTHENTIK_TOKEN env
#   echo "$AUTHENTIK_API_BASE"     # base URL for API calls (if forward set up)
#
# Variables consumed (set before sourcing):
#   AUTHENTIK_LOCAL_FORWARD_PORT   (default 18299) – only used when you call authentik_setup_forward
#   KUBECONFIG_FILE                – required for kubectl port-forward

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
# Read the shared Authentik secret from OpenBao (populates the variables below)
# ---------------------------------------------------------------------------
authentik_load_bootstrap_secret() {
  if [[ -n "${_AUTHENTIK_SECRET_LOADED:-}" ]]; then
    return 0
  fi

  command -v openbao_read_global_secret_json >/dev/null 2>&1 || \
    _authentik_fail "openbao_read_global_secret_json not available – source openbao-secret-sync.sh first"

  local secret_json
  secret_json="$(openbao_read_global_secret_json authentik)"
  [[ -n "$secret_json" && "$secret_json" != "null" ]] || \
    _authentik_fail "Could not read authentik secret from OpenBao"

  AUTHENTIK_BOOTSTRAP_TOKEN="$(jq -r '.AUTHENTIK_BOOTSTRAP_TOKEN // empty' <<<"$secret_json")"
  AUTHENTIK_BOOTSTRAP_PASSWORD="$(jq -r '.AUTHENTIK_BOOTSTRAP_PASSWORD // empty' <<<"$secret_json")"
  AUTHENTIK_HOST="$(jq -r '.AUTHENTIK_HOST // empty' <<<"$secret_json")"

  [[ -n "$AUTHENTIK_BOOTSTRAP_TOKEN" ]] || _authentik_fail "AUTHENTIK_BOOTSTRAP_TOKEN missing from OpenBao"
  [[ -n "$AUTHENTIK_BOOTSTRAP_PASSWORD" ]] || _authentik_fail "AUTHENTIK_BOOTSTRAP_PASSWORD missing from OpenBao"

  _AUTHENTIK_SECRET_LOADED=1
}

# ---------------------------------------------------------------------------
# Authenticate to Authentik and populate AUTHENTIK_TOKEN
#
# Strategy:
#   1. Try the bootstrap token directly (works during initial provisioning).
#   2. If 403, authenticate as akadmin via flow executor and create/reuse an API token.
#   3. Fallback to session cookie if token creation fails.
# ---------------------------------------------------------------------------
authentik_ensure_token() {
  authentik_load_bootstrap_secret

  AUTHENTIK_TOKEN="$AUTHENTIK_BOOTSTRAP_TOKEN"

  # Quick test: is the bootstrap token still valid?
  local test_url="${AUTHENTIK_HOST:+${AUTHENTIK_HOST}/api/v3}"
  if [[ -n "$test_url" ]]; then
    local test_status
    test_status="$(curl -sS -o /dev/null -w '%{http_code}' \
      "${test_url}/core/users/?page_size=1" \
      -H "Accept: application/json" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" 2>/dev/null)" || test_status="000"

    if [[ "$test_status" =~ ^2 ]]; then
      _authentik_log "Bootstrap token is valid"
      return 0
    fi
  fi

  # Bootstrap token is invalid or host not set – try flow-based auth
  _authentik_log "Bootstrap token invalid or host unknown; attempting flow-based authentication"
  _authentik_auth_via_flow || true

  # If we still have nothing useful, keep the bootstrap token and let the caller fail loudly
  if [[ -z "${AUTHENTIK_TOKEN:-}" ]]; then
    AUTHENTIK_TOKEN="$AUTHENTIK_BOOTSTRAP_TOKEN"
    _authentik_log "WARNING: falling back to bootstrap token (may fail if expired)"
  fi
}

# Internal: authenticate via flow executor and obtain a reusable API token.
_authentik_auth_via_flow() {
  local username="akadmin"
  local password="$AUTHENTIK_BOOTSTRAP_PASSWORD"

  # Determine the API base URL
  local api_base=""
  if [[ -n "${AUTHENTIK_LOCAL_FORWARD_PORT:-}" ]]; then
    api_base="http://127.0.0.1:${AUTHENTIK_LOCAL_FORWARD_PORT}/api/v3"
  elif [[ -n "${AUTHENTIK_HOST:-}" ]]; then
    api_base="${AUTHENTIK_HOST}/api/v3"
  else
    return 1
  fi

  local cookie_jar
  cookie_jar="$(mktemp)"
  trap "rm -f '$cookie_jar'" RETURN

  # Authenticate via the flow executor and capture session cookies
  curl -sS -X POST \
    "${api_base%/api/v3}/-/flow/executor/default-authentication-flow/" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg username "$username" --arg password "$password" '{username: $username, password: $password}')" \
    -c "$cookie_jar" \
    -o /dev/null 2>/dev/null || true

  # Try to create a permanent API token
  local token_response
  token_response="$(curl -sS -X POST \
    "${api_base}/core/tokens/" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -b "$cookie_jar" \
    -d '{"identifier":"twinbox-automation","intent":"api","expiring":false}' 2>/dev/null)" || token_response=""

  local api_token
  api_token="$(jq -r '.key // empty' <<<"$token_response" 2>/dev/null)" || api_token=""

  if [[ -n "$api_token" && "$api_token" != "null" ]]; then
    AUTHENTIK_TOKEN="$api_token"
    _authentik_log "Created API token for twinbox automation"
    return 0
  fi

  # Try to reuse an existing API token
  local existing_tokens
  existing_tokens="$(curl -sS \
    "${api_base}/core/tokens/" \
    -H "Accept: application/json" \
    -b "$cookie_jar" 2>/dev/null)" || existing_tokens=""

  local existing_token
  existing_token="$(jq -r '.results[]? | select(.intent == "api") | .key // empty' <<<"$existing_tokens" 2>/dev/null | head -n1)" || existing_token=""

  if [[ -n "$existing_token" && "$existing_token" != "null" ]]; then
    AUTHENTIK_TOKEN="$existing_token"
    _authentik_log "Reusing existing API token"
    return 0
  fi

  # Fallback to session cookie
  local session_id
  session_id="$(grep -oE 'session=[^;]+' "$cookie_jar" 2>/dev/null | head -n1)" || session_id=""

  if [[ -n "$session_id" ]]; then
    AUTHENTIK_TOKEN="$session_id"
    AUTHENTIK_USE_COOKIE="true"
    _authentik_log "Using session cookie for authentication"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Set up a kubectl port-forward to Authentik and populate AUTHENTIK_API_BASE
# Call this before making direct API calls that need a local forward.
# Sets: AUTHENTIK_API_BASE, AUTHENTIK_FORWARD_PID, AUTHENTIK_FORWARD_LOG
# ---------------------------------------------------------------------------
AUTHENTIK_FORWARD_PID=""
AUTHENTIK_FORWARD_LOG=""

authentik_setup_forward() {
  local port="${AUTHENTIK_LOCAL_FORWARD_PORT:-18299}"

  AUTHENTIK_FORWARD_LOG="$(mktemp "${TMPDIR:-/tmp}/authentik-port-forward.XXXXXX.log")"
  kubectl -n authentik port-forward "svc/authentik-server" "${port}:80" >"$AUTHENTIK_FORWARD_LOG" 2>&1 &
  AUTHENTIK_FORWARD_PID="$!"

  local attempt=1
  local attempts=60
  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsS "http://127.0.0.1:${port}/-/health/live/" >/dev/null 2>&1; then
      AUTHENTIK_API_BASE="http://127.0.0.1:${port}/api/v3"
      return 0
    fi
    if ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
      if [[ -s "$AUTHENTIK_FORWARD_LOG" ]]; then
        tail -n 20 "$AUTHENTIK_FORWARD_LOG" >&2
      fi
      _authentik_fail "Authentik port-forward on 127.0.0.1:${port} exited before ready"
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  _authentik_fail "Authentik port-forward on 127.0.0.1:${port} did not become ready"
}

authentik_teardown_forward() {
  if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]]; then
    kill "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  rm -f "${AUTHENTIK_FORWARD_LOG:-}"
}

# Register teardown on EXIT if this file was sourced in a script that uses it.
# Only register once per process.
if [[ -z "${_AUTHENTIK_FORWARD_TRAP_SET:-}" ]]; then
  trap 'authentik_teardown_forward' EXIT
  _AUTHENTIK_FORWARD_TRAP_SET=1
fi
