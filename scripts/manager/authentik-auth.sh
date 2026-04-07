#!/usr/bin/env bash
# Shared Authentik authentication helper.
# Sources openbao-secret-sync.sh prerequisite.
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
  AUTHENTIK_API_TOKEN="$(jq -r '.AUTHENTIK_API_TOKEN // empty' <<<"$secret_json")"

  [[ -n "$AUTHENTIK_BOOTSTRAP_TOKEN" ]] || _authentik_fail "AUTHENTIK_BOOTSTRAP_TOKEN missing from OpenBao"
  [[ -n "$AUTHENTIK_BOOTSTRAP_PASSWORD" ]] || _authentik_fail "AUTHENTIK_BOOTSTRAP_PASSWORD missing from OpenBao"

  _AUTHENTIK_SECRET_LOADED=1
}

# ---------------------------------------------------------------------------
# Populate AUTHENTIK_TOKEN from OpenBao.
# Prefers a persistent service-account API token (AUTHENTIK_API_TOKEN)
# so that API calls survive Authentik pod restarts / redeployments.
# Falls back to AUTHENTIK_BOOTSTRAP_TOKEN (only valid on first boot).
# ---------------------------------------------------------------------------
authentik_ensure_token() {
  authentik_load_bootstrap_secret
  if [[ -n "$AUTHENTIK_API_TOKEN" ]]; then
    _authentik_log "Using persistent API token"
    AUTHENTIK_TOKEN="$AUTHENTIK_API_TOKEN"
  else
    _authentik_log "No persistent API token found – falling back to bootstrap token"
    AUTHENTIK_TOKEN="$AUTHENTIK_BOOTSTRAP_TOKEN"
  fi
}

# ---------------------------------------------------------------------------
# Idempotently create a dedicated service account + non-expiring API token.
# Must be called after authentik_setup_forward (needs AUTHENTIK_API_BASE +
# AUTHENTIK_TOKEN set to the bootstrap token).
#
# Creates:
#   Service account: twinbox-automation
#   Token:           twinbox-automation-api-token (non-expiring)
#
# Stores the token key back into OpenBao as AUTHENTIK_API_TOKEN so all
# subsequent scripts get the persistent token via authentik_ensure_token().
# ---------------------------------------------------------------------------
AUTHENTIK_SA_NAME="${AUTHENTIK_SA_NAME:-twinbox-automation}"
AUTHENTIK_SA_TOKEN_IDENTIFIER="${AUTHENTIK_SA_TOKEN_IDENTIFIER:-twinbox-automation-api-token}"

authentik_create_service_account_token() {
  if [[ -n "${AUTHENTIK_API_TOKEN:-}" ]]; then
    _authentik_log "Persistent API token already exists in OpenBao – skipping service account creation"
    return 0
  fi

  _authentik_log "Creating service account '${AUTHENTIK_SA_NAME}'"

  # --- Check if service account already exists ---
  local sa_json
  sa_json="$(curl -sS \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    "${AUTHENTIK_API_BASE}/core/users/?type=service_account&search=${AUTHENTIK_SA_NAME}" \
  )" || _authentik_fail "Failed to query existing service accounts"

  local sa_pk
  sa_pk="$(printf '%s' "$sa_json" | jq -r '
    (.results // [])
    | map(select(.username == $name))
    | .[0].pk // empty
  ' --arg name "$AUTHENTIK_SA_NAME")"

  if [[ -n "$sa_pk" ]]; then
    _authentik_log "Service account '${AUTHENTIK_SA_NAME}' already exists (pk=${sa_pk})"
  else
    # --- Create service account ---
    sa_json="$(curl -sS --fail \
      -X POST \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -d "$(jq -nc --arg name "$AUTHENTIK_SA_NAME" '{name: $name}')" \
      "${AUTHENTIK_API_BASE}/core/users/service_account/" \
    )" || _authentik_fail "Failed to create service account '${AUTHENTIK_SA_NAME}'"

    sa_pk="$(printf '%s' "$sa_json" | jq -r '.pk // .id // .user_pk // empty')"
    [[ -n "$sa_pk" ]] || _authentik_fail "Could not determine service account pk from response: $sa_json"
    _authentik_log "Created service account '${AUTHENTIK_SA_NAME}' (pk=${sa_pk})"
  fi

  # --- Check if token object already exists ---
  local token_json
  token_json="$(curl -sS \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    "${AUTHENTIK_API_BASE}/core/tokens/?identifier=${AUTHENTIK_SA_TOKEN_IDENTIFIER}" \
  )" || _authentik_fail "Failed to query existing tokens"

  local token_exists
  token_exists="$(printf '%s' "$token_json" | jq -r '
    (.results // [])
    | map(select(.identifier == $id))
    | length > 0
  ' --arg id "$AUTHENTIK_SA_TOKEN_IDENTIFIER")"

  if [[ "$token_exists" == "true" ]]; then
    _authentik_fail "Token '${AUTHENTIK_SA_TOKEN_IDENTIFIER}' already exists but key is not stored in OpenBao – manual intervention required"
  fi

  # --- Create token object ---
  _authentik_log "Creating non-expiring API token '${AUTHENTIK_SA_TOKEN_IDENTIFIER}'"

  local token_key
  token_key="$(openssl rand -hex 32)"

  token_json="$(curl -sS --fail \
    -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -d "$(jq -nc \
      --arg identifier "$AUTHENTIK_SA_TOKEN_IDENTIFIER" \
      --argjson user "$sa_pk" \
      '{
        identifier: $identifier,
        user: $user,
        expiring: false
      }')" \
    "${AUTHENTIK_API_BASE}/core/tokens/" \
  )" || _authentik_fail "Failed to create token '${AUTHENTIK_SA_TOKEN_IDENTIFIER}'"

  # --- Set explicit token key ---
  curl -sS --fail \
    -X POST \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -d "$(jq -nc --arg key "$token_key" '{key: $key}')" \
    "${AUTHENTIK_API_BASE}/core/tokens/${AUTHENTIK_SA_TOKEN_IDENTIFIER}/set_key/" \
    >/dev/null || _authentik_fail "Failed to set token key for '${AUTHENTIK_SA_TOKEN_IDENTIFIER}'"

  _authentik_log "Token key generated and set"

  # --- Persist the token key in OpenBao ---
  if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
    local current_secret
    current_secret="$(openbao_read_global_secret_json authentik)"
    local updated_secret
    updated_secret="$(printf '%s' "$current_secret" | jq \
      --arg api_token "$token_key" \
      '. + {AUTHENTIK_API_TOKEN: $api_token}' \
    )"

    local tmp_file
    tmp_file="$(mktemp)"
    printf '%s' "$updated_secret" >"$tmp_file"

    _authentik_log "Persisting AUTHENTIK_API_TOKEN in OpenBao"
    bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
      --secret-name "authentik" \
      --json-file "$tmp_file" \
      --required-keys "AUTHENTIK_BOOTSTRAP_TOKEN,AUTHENTIK_API_TOKEN"

    rm -f "$tmp_file"
  fi

  # Update in-memory value for the rest of this script run
  AUTHENTIK_API_TOKEN="$token_key"
  AUTHENTIK_TOKEN="$token_key"

  _authentik_log "Service account token creation complete"
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
