#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
wiredoor_secret_file="$BOOTSTRAP_ROOT/secrets/global/wiredoor-gateway.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/wiredoor-gateway.yaml"

[[ -f "$wiredoor_secret_file" ]] || {
  echo "Wiredoor bootstrap secret file missing: $wiredoor_secret_file" >&2
  exit 1
}

wiredoor_url="$(jq -r '."WIREDOOR_URL" // empty' "$wiredoor_secret_file")"
[[ -n "$wiredoor_url" ]] || {
  echo "WIREDOOR_URL missing in $wiredoor_secret_file" >&2
  exit 1
}

wiredoor_token="$(jq -r '."TOKEN" // empty' "$wiredoor_secret_file")"
if [[ -z "$wiredoor_token" ]]; then
  wiredoor_token="$(openssl rand -hex 24)"
  tmp_file="$(mktemp)"
  jq --arg token "$wiredoor_token" '. + {TOKEN: $token}' "$wiredoor_secret_file" >"$tmp_file"
  install -m 600 "$tmp_file" "$wiredoor_secret_file"
  rm -f "$tmp_file"
fi

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "wiredoor-gateway" \
  --json-file "$wiredoor_secret_file" \
  --required-keys "WIREDOOR_URL,TOKEN"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "wiredoor-gateway"
