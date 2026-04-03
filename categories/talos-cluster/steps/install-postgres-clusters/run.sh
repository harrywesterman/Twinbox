#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
authentik_secret_file="$BOOTSTRAP_ROOT/secrets/global/authentik.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/postgres-clusters.yaml"

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

seed_authentik_db_secret

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "postgres-clusters"
