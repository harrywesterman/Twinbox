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
# Create an API token for akadmin via kubectl exec in the Authentik pod.
# This bypasses the need for flow-based authentication entirely.
# The token is persisted in OpenBao so subsequent runs reuse it.
# ---------------------------------------------------------------------------
authentik_create_api_token() {
  local identifier="${1:-twinbox-automation}"
  local pod=""

  pod="$(kubectl get pod -n authentik -l app.kubernetes.io/name=authentik,app.kubernetes.io/instance=authentik -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase == "Running") | select(.metadata.labels["app.kubernetes.io/component"] == "server") | .metadata.name' | head -n1)" || true

  if [[ -z "$pod" ]]; then
    _authentik_log "No running Authentik server pod found for API token creation"
    return 1
  fi

  _authentik_log "Creating API token for akadmin via pod exec"

  local token_raw
  token_raw="$(kubectl exec -n authentik "$pod" -- ak shell -c "
from authentik.core.models import User, Token
user = User.objects.filter(username='akadmin').first()
if not user:
    print('ERROR: akadmin user not found')
    exit(1)
Token.objects.filter(identifier='${identifier}', user=user, intent='api').delete()
token = Token.objects.create(
    identifier='${identifier}',
    user=user,
    intent='api',
    expiring=False,
)
print('TOKEN_START' + token.key + 'TOKEN_END')
" 2>/dev/null)" || true

  # Extract just the token from the log-heavy output
  local token_key
  token_key="$(echo "$token_raw" | grep -oE 'TOKEN_START[a-zA-Z0-9]+TOKEN_END' | sed 's/TOKEN_START//;s/TOKEN_END//')" || true

  if [[ -z "$token_key" || "$token_key" == *"ERROR"* || "$token_key" == *"Traceback"* ]]; then
    _authentik_log "Failed to create API token via pod exec"
    return 1
  fi

  # Store the token in OpenBao so subsequent steps can use it directly
  local openbao_pod=""
  openbao_pod="$(kubectl get pod -n openbao -l app.kubernetes.io/name=openbao -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' | head -n1)" || true

  if [[ -n "$openbao_pod" ]]; then
    local root_token=""
    local bootstrap_root="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
    if [[ -f "$bootstrap_root/openbao/init/root-token" ]]; then
      root_token="$(tr -d '\r\n' <"$bootstrap_root/openbao/init/root-token")"
    fi

    if [[ -n "$root_token" ]]; then
      local forward_port="${OPENBAO_LOCAL_FORWARD_PORT:-18200}"
      local forward_log
      forward_log="$(mktemp "${TMPDIR:-/tmp}/openbao-port-forward.XXXXXX.log")"
      local forward_pid=""

      kubectl -n openbao port-forward "pod/${openbao_pod}" "${forward_port}:8200" >"$forward_log" 2>&1 &
      forward_pid="$!"

      local attempt=1
      while [[ "$attempt" -le 20 ]]; do
        if curl -fsS "http://127.0.0.1:${forward_port}/v1/sys/health" >/dev/null 2>&1; then
          break
        fi
        sleep 1
        attempt=$((attempt + 1))
      done

      if [[ "$attempt" -le 20 ]]; then
        # Read current secret and update with the API token
        local current
        current="$(curl -fsS -H "X-Vault-Token: ${root_token}" \
          "http://127.0.0.1:${forward_port}/v1/kv/data/twinbox/global/authentik" 2>/dev/null | jq -c '.data.data // {}')" || current="{}"

        curl -fsS -X POST \
          -H "Content-Type: application/json" \
          -H "X-Vault-Token: ${root_token}" \
          --data-binary "$(jq -n --argjson current "$current" --arg api_token "$token_key" \
            '{data: ($current + {AUTHENTIK_API_TOKEN: $api_token})}')" \
          "http://127.0.0.1:${forward_port}/v1/kv/data/twinbox/global/authentik" >/dev/null 2>&1 || true

        _authentik_log "Stored AUTHENTIK_API_TOKEN in OpenBao"
      fi

      kill "$forward_pid" >/dev/null 2>&1 || true
      wait "$forward_pid" >/dev/null 2>&1 || true
      rm -f "$forward_log"
    fi
  fi

  AUTHENTIK_TOKEN="$token_key"
  AUTHENTIK_USE_COOKIE="false"
  _authentik_log "API token created successfully"
  return 0
}

# ---------------------------------------------------------------------------
# Authenticate to Authentik and populate AUTHENTIK_TOKEN
#
# Strategy:
#   1. Check for existing AUTHENTIK_API_TOKEN in OpenBao (persisted token).
#   2. Try the bootstrap token directly (works during initial provisioning).
#   3. Create a new API token via kubectl exec in the Authentik pod.
# ---------------------------------------------------------------------------
authentik_ensure_token() {
  authentik_load_bootstrap_secret

  # Strategy 1: Check for a persisted API token in OpenBao
  local persisted_token=""
  persisted_token="$(openbao_read_global_secret_json authentik | jq -r '.AUTHENTIK_API_TOKEN // empty' 2>/dev/null)" || persisted_token=""

  if [[ -n "$persisted_token" && "$persisted_token" != "null" ]]; then
    AUTHENTIK_TOKEN="$persisted_token"
    _authentik_log "Using persisted AUTHENTIK_API_TOKEN from OpenBao"
    return 0
  fi

  # Strategy 2: Try the bootstrap token directly (may work on fresh installs)
  AUTHENTIK_TOKEN="$AUTHENTIK_BOOTSTRAP_TOKEN"

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

  # Strategy 3: Create a new API token via pod exec
  if authentik_create_api_token "twinbox-automation"; then
    return 0
  fi

  # Last resort: keep the bootstrap token and let the caller fail with a clear error
  _authentik_fail "Could not obtain a valid Authentik API token. Bootstrap token is invalid and API token creation failed."
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
