#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout=15s >/dev/null 2>&1; then
      log "Deployment/${deployment} is ready"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for Deployment/${deployment}"
    fi

    log "Waiting for Deployment/${deployment}"
    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_cloudshell() {
  local namespace="$1"
  local name="$2"
  local attempts=120
  local attempt=1

  while true; do
    local phase=""
    local url=""
    phase="$(kubectl -n "$namespace" get cloudshell "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    url="$(kubectl -n "$namespace" get cloudshell "$name" -o jsonpath='{.status.accessUrl}' 2>/dev/null || true)"
    if [[ "$phase" == "Ready" && -n "$url" ]]; then
      log "CloudShell/${name} is ready at ${url}"
      printf '%s\n' "$url"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for CloudShell/${name}"
    fi

    log "Waiting for CloudShell/${name}"
    sleep 5
    attempt=$((attempt + 1))
  done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
[[ -n "${STEP_CONTEXT_JSON:-}" ]] || fail "STEP_CONTEXT_JSON is required"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v helm >/dev/null 2>&1 || fail "helm not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

NAMESPACE="${CLOUDTTY_NAMESPACE:-cloudtty-system}"
RELEASE_NAME="${CLOUDTTY_RELEASE_NAME:-cloudtty-operator}"
CHART_NAME="${CLOUDTTY_CHART_NAME:-cloudtty/cloudtty}"
CLOUDSHELL_NAME="${CLOUDTTY_CLOUDSHELL_NAME:-cloudtty-shell}"
CONTROLLER_DEPLOYMENT_NAME="${RELEASE_NAME}-controller-manager"
PLATFORM_DIR="$WORKSPACE_ROOT/gitops/platform-apps/cloudtty"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
[[ -n "$cluster_slug" ]] || fail "Could not determine cluster slug from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"
rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/cloudtty-ingressroute.XXXXXX.yaml")"
trap 'rm -f "$rendered_ingressroute"' EXIT

log "Adding cloudtty Helm repository"
if ! helm repo list 2>/dev/null | awk '$1 == "cloudtty" { found = 1 } END { exit found ? 0 : 1 }'; then
  helm repo add cloudtty https://cloudtty.github.io/cloudtty >/dev/null
fi
helm repo update >/dev/null

log "Installing cloudtty operator into ${NAMESPACE}"
helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
  --version "$PINNED_CLOUDTTY_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 10m

wait_for_deployment "$NAMESPACE" "$CONTROLLER_DEPLOYMENT_NAME"

log "Applying CloudShell resource"
kubectl apply -f - <<EOF
apiVersion: cloudshell.cloudtty.io/v1alpha1
kind: CloudShell
metadata:
  name: ${CLOUDSHELL_NAME}
  namespace: ${NAMESPACE}
spec:
  exposureMode: NodePort
  commandAction: bash
  once: false
EOF

cloudshell_url="$(wait_for_cloudshell "$NAMESPACE" "$CLOUDSHELL_NAME")"
kubectl apply -f "$PLATFORM_DIR/authentik-forwardauth-middleware.yaml"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$PLATFORM_DIR/ingressroute.yaml" >"$rendered_ingressroute"
kubectl apply -f "$rendered_ingressroute"
log "Cloudtty ready at ${cloudshell_url}"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg release_name "$RELEASE_NAME" \
    --arg chart_name "$CHART_NAME" \
    --arg cloudshell_name "$CLOUDSHELL_NAME" \
    --arg controller_deployment_name "$CONTROLLER_DEPLOYMENT_NAME" \
    --arg access_url "$cloudshell_url" \
    --arg chart_version "$PINNED_CLOUDTTY_CHART_VERSION" \
    '{
      namespace: $namespace,
      release_name: $release_name,
      chart_name: $chart_name,
      chart_version: $chart_version,
      controller_deployment_name: $controller_deployment_name,
      cloudshell_name: $cloudshell_name,
      access_url: $access_url
    }' >"$STEP_RESULT_FILE"
fi
