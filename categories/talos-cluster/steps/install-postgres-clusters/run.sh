#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
authentik_secret_file="$BOOTSTRAP_ROOT/secrets/global/authentik.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/postgres-clusters.yaml"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

mkdir -p "$(dirname "$authentik_secret_file")"

seed_authentik_db_secret() {
  local authentik_postgresql_user=""
  local authentik_postgresql_password=""
  local tmp_file

  if [[ -f "$authentik_secret_file" ]]; then
    authentik_postgresql_user="$(jq -r '."AUTHENTIK_POSTGRESQL__USER" // ."AUTHENTIK_POSTGRESQL__USERNAME" // empty' "$authentik_secret_file")"
    authentik_postgresql_password="$(jq -r '."AUTHENTIK_POSTGRESQL__PASSWORD" // empty' "$authentik_secret_file")"
  fi

  if [[ -z "$authentik_postgresql_user" ]]; then
    authentik_postgresql_user="authentik"
  fi

  if [[ -z "$authentik_postgresql_password" ]]; then
    authentik_postgresql_password="$(openssl rand -hex 16)"
  fi

  tmp_file="$(mktemp)"
  jq -n \
    --arg authentik_postgresql_user "$authentik_postgresql_user" \
    --arg authentik_postgresql_password "$authentik_postgresql_password" \
    '{
      "AUTHENTIK_POSTGRESQL__USER": $authentik_postgresql_user,
      "AUTHENTIK_POSTGRESQL__USERNAME": $authentik_postgresql_user,
      "AUTHENTIK_POSTGRESQL__PASSWORD": $authentik_postgresql_password
    }' >"$tmp_file"
  install -m 600 "$tmp_file" "$authentik_secret_file"
  rm -f "$tmp_file"

  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "authentik" \
    --json-file "$authentik_secret_file" \
    --required-keys "AUTHENTIK_POSTGRESQL__USER,AUTHENTIK_POSTGRESQL__USERNAME,AUTHENTIK_POSTGRESQL__PASSWORD"
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

seed_authentik_db_secret

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "postgres-clusters" \
  --no-wait

wait_for_resources_ready "databases" "cluster" "Ready" "CloudNativePG cluster"
wait_for_resources_ready "databases" "externalsecret" "Ready" "ExternalSecret"
wait_for_resources_ready "databases" "deployment" "Available" "Pooler deployment"
