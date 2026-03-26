#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"

bash scripts/manager/install-argocd.sh

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg bootstrap_root_application "root" \
    --argjson bootstrap_applications '["whoami","headlamp"]' \
    '{
      cluster_id: $cluster_id,
      bootstrap_root_application: $bootstrap_root_application,
      bootstrap_applications: $bootstrap_applications
    }' >"$STEP_RESULT_FILE"
fi
