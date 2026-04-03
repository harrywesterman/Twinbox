#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"
manifest_path="$WORKSPACE_ROOT/gitops/apps/ntfy.yaml"

kubectl delete application ntfy -n argocd --ignore-not-found=true 2>/dev/null || true

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "ntfy" \
  --destination-namespace "monitoring"

