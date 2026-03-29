#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
grafana_secret_file="$BOOTSTRAP_ROOT/secrets/global/grafana.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/grafana.yaml"

mkdir -p "$(dirname "$grafana_secret_file")"

if [[ ! -f "$grafana_secret_file" ]]; then
  grafana_password="$(openssl rand -hex 16)"
  tmp_file="$(mktemp)"
  jq -n \
    --arg admin_user "admin" \
    --arg admin_password "$grafana_password" \
    '{
      "admin-user": $admin_user,
      "admin-password": $admin_password
    }' >"$tmp_file"
  install -m 600 "$tmp_file" "$grafana_secret_file"
  rm -f "$tmp_file"
fi

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "grafana" \
  --json-file "$grafana_secret_file" \
  --required-keys "admin-user,admin-password"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "grafana"
