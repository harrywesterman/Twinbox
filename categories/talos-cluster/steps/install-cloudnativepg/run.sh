#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
manifest_path="$WORKSPACE_ROOT/gitops/apps/cloudnativepg.yaml"
databases_manifest_path="$WORKSPACE_ROOT/gitops/apps/databases.yaml"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "cloudnativepg"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$databases_manifest_path" \
  --application "databases"
