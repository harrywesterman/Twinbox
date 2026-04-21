#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"

export KUBECONFIG="$KUBECONFIG_FILE"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/tempo.yaml" \
  --application "tempo" \
  --destination-namespace "monitoring"
