#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?missing KUBECONFIG}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TEMPLATE_DIR="$WORKSPACE_ROOT/coder/templates/twinbox"
TEMPLATE_NAME="${TEMPLATE_NAME:-twinbox}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

CODER_NAMESPACE="${CODER_NAMESPACE:-coder}"
CODER_SERVICE="${CODER_SERVICE:-coder}"
CODER_URL="${CODER_URL:-}"

if [[ -z "$CODER_URL" ]]; then
  log "Discovering Coder URL from cluster IngressRoute..."
  CODER_URL="$(kubectl -n "$CODER_NAMESPACE" get ingressroute coder -o jsonpath='{.spec.routes[0].match}' 2>/dev/null | sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' || true)"
  if [[ -z "$CODER_URL" ]]; then
    CODER_URL="http://${CODER_SERVICE}.${CODER_NAMESPACE}.svc.cluster.local:3000"
  else
    CODER_URL="https://${CODER_URL}"
  fi
fi

log "Using Coder URL: $CODER_URL"

CODER_SESSION_TOKEN="${CODER_SESSION_TOKEN:-}"

if [[ -z "$CODER_SESSION_TOKEN" ]]; then
  log "No CODER_SESSION_TOKEN set; attempting to create one via the Coder API..."

  CODER_POD="$(kubectl -n "$CODER_NAMESPACE" get pod -l app.kubernetes.io/name=coder -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$CODER_POD" ]]; then
    fail "Could not find a running Coder pod in namespace $CODER_NAMESPACE"
  fi

  if kubectl -n "$CODER_NAMESPACE" get secret coder-admin-token &>/dev/null; then
    log "Using existing coder-admin-token secret"
    CODER_SESSION_TOKEN="$(kubectl -n "$CODER_NAMESPACE" get secret coder-admin-token -o jsonpath='{.data.token}' | base64 -d)"
  else
    log "Creating first admin user and token via Coder API..."

    ADMIN_USERNAME="${CODER_ADMIN_USERNAME:-admin}"
    ADMIN_EMAIL="${CODER_ADMIN_EMAIL:-admin@twinbox.local}"
    ADMIN_PASSWORD="$(openssl rand -hex 16)"

    kubectl -n "$CODER_NAMESPACE" exec "$CODER_POD" -- sh -c "
      curl -sS -X POST 'http://localhost:3000/api/v2/users/first' \
        -H 'Content-Type: application/json' \
        -d '{\"username\":\"${ADMIN_USERNAME}\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}' 2>/dev/null
    " >/dev/null 2>&1 || true

    sleep 3

    USER_ID="$(kubectl -n "$CODER_NAMESPACE" exec "$CODER_POD" -- sh -c "
      curl -sS 'http://localhost:3000/api/v2/users' -H 'Content-Type: application/json' 2>/dev/null | jq -r '.users[]? | select(.username == \"${ADMIN_USERNAME}\") | .id // empty'
    " 2>/dev/null || true)"

    if [[ -z "$USER_ID" ]]; then
      USER_ID="$(kubectl -n "$CODER_NAMESPACE" exec "$CODER_POD" -- sh -c "
        curl -sS -X POST 'http://localhost:3000/api/v2/users/login' \
          -H 'Content-Type: application/json' \
          -d '{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}' 2>/dev/null | jq -r '.user_id // .id // empty'
      " 2>/dev/null || true)"
    fi

    if [[ -n "$USER_ID" ]]; then
      log "Creating API token for admin user $USER_ID"
      TOKEN_RESPONSE="$(kubectl -n "$CODER_NAMESPACE" exec "$CODER_POD" -- sh -c "
        curl -sS -X POST 'http://localhost:3000/api/v2/users/${USER_ID}/keys' \
          -H 'Content-Type: application/json' \
          -d '{\"lifetime\":0}' 2>/dev/null
      " 2>/dev/null || true)"
      CODER_SESSION_TOKEN="$(jq -r '.key // empty' <<<"$TOKEN_RESPONSE" 2>/dev/null || true)"

      if [[ -n "$CODER_SESSION_TOKEN" ]]; then
        kubectl -n "$CODER_NAMESPACE" create secret generic coder-admin-token \
          --from-literal="token=${CODER_SESSION_TOKEN}" \
          --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        log "Stored admin token in secret coder-admin-token"
      fi
    fi
  fi
fi

if [[ -z "$CODER_SESSION_TOKEN" ]]; then
  fail "Could not obtain a Coder session token. Log in to $CODER_URL, create a token, and export CODER_SESSION_TOKEN."
fi

if ! command -v coder &>/dev/null; then
  log "Downloading Coder CLI..."
  CACHED_CLI="/tmp/coder-cli"
  if [[ ! -f "$CACHED_CLI" ]]; then
    curl -fsSL "https://github.com/coder/coder/releases/latest/download/coder-linux-amd64.tar.gz" -o /tmp/coder.tar.gz
    tar -xzf /tmp/coder.tar.gz -C /tmp
    install -m 0755 /tmp/coder /usr/local/bin/coder
    rm -rf /tmp/coder.tar.gz /tmp/coder
  fi
fi

log "Logging in to Coder..."
CODER_SESSION_TOKEN="$CODER_SESSION_TOKEN" coder login "$CODER_URL" --use-token-as-session >/dev/null 2>&1 || {
  coder login "$CODER_URL" --token "$CODER_SESSION_TOKEN" >/dev/null 2>&1 || {
    fail "Coder login failed. Check CODER_URL and CODER_SESSION_TOKEN."
  }
}

TEMPLATE_VERSION="${TEMPLATE_VERSION:-$(date +%Y%m%d%H%M%S)}"
if [[ -n "${GITHUB_SHA:-}" ]]; then
  TEMPLATE_VERSION="${GITHUB_SHA:0:7}"
fi

log "Pushing template: $TEMPLATE_NAME (version: $TEMPLATE_VERSION) from $TEMPLATE_DIR"
coder templates push "$TEMPLATE_NAME" \
  --directory "$TEMPLATE_DIR" \
  --name="$TEMPLATE_VERSION" \
  --yes \
  --activate \
  --variables-file <(echo '') 2>/dev/null || \
coder templates push "$TEMPLATE_NAME" \
  --directory "$TEMPLATE_DIR" \
  --name="$TEMPLATE_VERSION" \
  --yes \
  --activate

log "Template $TEMPLATE_NAME version $TEMPLATE_VERSION pushed and activated"
