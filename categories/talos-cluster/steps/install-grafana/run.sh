#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
grafana_secret_file="$BOOTSTRAP_ROOT/secrets/global/grafana.json"

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

bash "$WORKSPACE_ROOT/scripts/manager/enable-argocd-apps.sh" \
  --cluster-id "$cluster_id" \
  --enabled-apps "grafana" \
  --applications "grafana-secret,grafana,grafana-routes"
