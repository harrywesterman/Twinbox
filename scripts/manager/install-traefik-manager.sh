#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

platform_dir="$WORKSPACE_ROOT/gitops/platform-apps/traefik-manager"
rendered_deployment="$(mktemp "${TMPDIR:-/tmp}/traefik-manager-deployment.XXXXXX.yaml")"
rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/traefik-manager-ingressroute.XXXXXX.yaml")"
trap 'rm -f "$rendered_deployment" "$rendered_ingressroute"' EXIT

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_slug" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine cluster slug from STEP_CONTEXT_JSON" >&2
  exit 1
}
[[ -n "$cluster_dns_domain" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine cluster DNS domain from STEP_CONTEXT_JSON" >&2
  exit 1
}

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine public zone name" >&2
  exit 1
}

kubectl apply -f "$platform_dir/namespace.yaml"
kubectl apply -f "$platform_dir/serviceaccount.yaml"
kubectl apply -f "$platform_dir/pvc.yaml"
kubectl apply -f "$platform_dir/service.yaml"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$platform_dir/deployment.yaml" >"$rendered_deployment"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$platform_dir/ingressroute.yaml" >"$rendered_ingressroute"
kubectl apply -f "$rendered_deployment"
kubectl apply -f "$rendered_ingressroute"
