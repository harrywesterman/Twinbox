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

if [[ -z "${_AUTHENTIK_FORWARD_TRAP_SET:-}" ]]; then
  trap 'authentik_teardown_forward' EXIT
  _AUTHENTIK_FORWARD_TRAP_SET=1
fi
