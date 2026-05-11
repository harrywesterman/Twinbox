#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
manifest_path="$WORKSPACE_ROOT/gitops/apps/traefik.yaml"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "traefik" \
  --no-wait

KUBECONFIG="$KUBECONFIG_FILE" kubectl -n traefik rollout status deployment/traefik --timeout=300s

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "traefik" \
    --arg manifest_path "$manifest_path" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
