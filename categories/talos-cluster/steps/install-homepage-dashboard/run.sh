#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
manifest_path="$WORKSPACE_ROOT/gitops/apps/homepage-dashboard.yaml"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "homepage-dashboard"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "homepage-dashboard" \
    --arg manifest_path "$manifest_path" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi
