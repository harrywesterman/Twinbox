#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
export KUBECONFIG="$KUBECONFIG_FILE"
manifest_path="$WORKSPACE_ROOT/gitops/apps/ntfy.yaml"

kubectl delete application ntfy -n argocd --ignore-not-found=true 2>/dev/null || true
kubectl delete applicationset ntfy-set -n argocd --ignore-not-found=true 2>/dev/null || true

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "ntfy" \
  --destination-namespace "monitoring"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "ntfy" \
  --service-domain "ntfy.${public_zone_name}" \
  --service-path /
