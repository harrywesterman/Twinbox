#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
cert_manager_manifest_path="$WORKSPACE_ROOT/gitops/apps/cert-manager.yaml"
manifest_path="$WORKSPACE_ROOT/gitops/apps/cloudnativepg.yaml"
barman_cloud_plugin_manifest_path="$WORKSPACE_ROOT/gitops/apps/cloudnativepg-barman-cloud.yaml"
databases_manifest_path="$WORKSPACE_ROOT/gitops/apps/databases.yaml"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$cert_manager_manifest_path" \
  --application "cert-manager"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "cloudnativepg"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$barman_cloud_plugin_manifest_path" \
  --application "cloudnativepg-barman-cloud"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$databases_manifest_path" \
  --application "databases"
