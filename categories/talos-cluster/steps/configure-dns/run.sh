#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"

dns_provider="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dns_provider')"
dns_api_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dns_api_token')"
dns_api_secret="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dns_api_secret // empty')"
cluster_dns_domain="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dns_domain')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$dns_provider" ]] || fail "DNS provider is required"
[[ -n "$dns_api_token" ]] || fail "DNS API token is required"
[[ -n "$cluster_dns_domain" ]] || fail "DNS domain is required"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring external-dns for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provider: $dns_provider"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Zone: $public_zone_name"

# Persist dns_domain and public_zone_name to the cluster file
cluster_file="$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
if [[ -f "$cluster_file" ]]; then
  tmp_file="$(mktemp)"
  jq \
    --arg dns_domain "$cluster_dns_domain" \
    --arg public_zone_name "$public_zone_name" \
    --arg dns_provider "$dns_provider" \
    '.dns_domain = $dns_domain | .public_zone_name = $public_zone_name | .selected_dns_provider = $dns_provider' \
    "$cluster_file" > "$tmp_file"
  mv "$tmp_file" "$cluster_file"
fi

# Create namespace and Kubernetes Secret with provider credentials
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -

case "$dns_provider" in
  cloudflare)
    kubectl create secret generic external-dns-credentials \
      --namespace=external-dns \
      --from-literal=token="$dns_api_token" \
      --dry-run=client -o yaml | kubectl apply -f -
    ;;
  aws)
    [[ -n "$dns_api_secret" ]] || fail "AWS Secret Access Key is required"
    kubectl create secret generic external-dns-credentials \
      --namespace=external-dns \
      --from-literal=access-key="$dns_api_token" \
      --from-literal=secret-key="$dns_api_secret" \
      --dry-run=client -o yaml | kubectl apply -f -
    ;;
  digitalocean)
    kubectl create secret generic external-dns-credentials \
      --namespace=external-dns \
      --from-literal=token="$dns_api_token" \
      --dry-run=client -o yaml | kubectl apply -f -
    ;;
  google)
    kubectl create secret generic external-dns-credentials \
      --namespace=external-dns \
      --from-literal=google-credentials="$dns_api_token" \
      --dry-run=client -o yaml | kubectl apply -f -
    ;;
  *)
    fail "Unsupported DNS provider: $dns_provider"
    ;;
esac

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Credentials stored in secret/external-dns-credentials"

# Render and apply the Argo CD Application manifest
repo_url="${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
target_rev="${TWINBOX_GIT_TARGET_REVISION:-main}"

rendered_manifest="$(sed \
  "s|__REPO_URL__|${repo_url}|g; \
   s|__TARGET_REVISION__|${target_rev}|g; \
   s|__DNS_PROVIDER__|${dns_provider}|g; \
   s|__DNS_ZONE__|${public_zone_name}|g" \
  "$WORKSPACE_ROOT/gitops/apps/external-dns.yaml")"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying external-dns Argo CD Application"
printf '%s\n' "$rendered_manifest" | kubectl apply --validate=false -f -
kubectl annotate application external-dns -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

# Wait for deployment to be ready
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for external-dns deployment to be ready"
kubectl rollout status deployment/external-dns -n external-dns --timeout=120s || \
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: rollout timed out, continuing"

# Mark cluster as domain-ready in Argo CD
bash "$WORKSPACE_ROOT/scripts/manager/upsert-argocd-cluster-secret.sh" \
  --public-zone-name "$public_zone_name"

# Apply platform-ingress ApplicationSet
if command -v kubectl &>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying platform-ingress application"
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
    --application "platform-ingress" \
    --destination-namespace "argocd"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] external-dns configured successfully for $public_zone_name"

# Write step result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "dns_provider": "$dns_provider",
  "dns_zone": "$public_zone_name",
  "cluster_id": "$cluster_id"
}
EOF
fi
