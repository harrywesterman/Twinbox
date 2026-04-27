#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

resolve_kubeconfig_file() {
  if [[ -z "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE is required"
  fi

  if [[ ! -f "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE does not exist at ${KUBECONFIG_FILE:-}"
  fi

  printf '%s\n' "$KUBECONFIG_FILE"
}

export KUBECONFIG
KUBECONFIG="$(resolve_kubeconfig_file)"

cluster_json="$(jq -c '.cluster // empty' <<<"$STEP_CONTEXT_JSON")"
cluster_id="$(jq -r '.id // empty' <<<"$cluster_json")"
cluster_slug="$(jq -r '.slug // empty' <<<"$cluster_json")"
cluster_dns_domain="$(jq -r '.dns_domain // empty' <<<"$cluster_json")"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

log "Installing Garage S3 for cluster $cluster_id"

STORAGE_SIZE="${storage_size:-50Gi}"
S3_PORT="${s3_port:-8000}"

log "Creating namespace"
kubectl create namespace garage --dry-run=client -o yaml | kubectl apply -f -

log "Adding Garage helm repo"
if ! helm repo list 2>/dev/null | awk '$1 == "garage" { found = 1 } END { exit found ? 0 : 1 }'; then
  helm repo add garage-helm https://datahub-local.github.io/garage-helm >/dev/null 2>&1 || true
fi
helm repo update >/dev/null 2>&1 || true

garage_values_file="$(mktemp "${TMPDIR:-/tmp}/garage-values.XXXXXX.yaml")"
trap 'rm -f "$garage_values_file"' EXIT

cat > "$garage_values_file" <<VALUES
replicaCount: 1

persistence:
  enabled: true
  storageClass: longhorn
  size: ${STORAGE_SIZE}
  accessMode: ReadWriteOnce

service:
  type: ClusterIP
  ports:
    s3: ${S3_PORT}

s3:
  enabled: true
  domain: garage.${public_zone_name}
  port: ${S3_PORT}

# Create a bucket for Nextcloud
bootstrap:
  enabled: true
  buckets:
    - name: nextcloud-data
      policy: private

# Generate admin API key
admin:
  enabled: true
  createApiKey: true

# Metrics
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
VALUES

log "Installing Garage via helm"
helm upgrade --install garage garage-helm/garage \
  --namespace garage \
  --values "$garage_values_file" \
  --wait --timeout 300s

log "Waiting for Garage to be ready"
kubectl -n garage rollout status deployment/garage --timeout=300s

log "Getting Garage S3 credentials"
garage_access_key="$(kubectl -n garage get secret garage-api-keys -o jsonpath='{.data.admin-access-key}' 2>/dev/null | base64 -d || echo "")"
garage_secret_key="$(kubectl -n garage get secret garage-api-keys -o jsonpath='{.data.admin-secret-key}' 2>/dev/null | base64 -d || echo "")"

if [[ -z "$garage_access_key" || -z "$garage_secret_key" ]]; then
  log "No API key secret found, trying alternative method..."
  
  garage_pod=$(kubectl -n garage get pods -l app.kubernetes.io/name=garage -o name 2>/dev/null | head -1 | sed 's|pods/||')
  if [[ -n "$garage_pod" ]]; then
    garage_access_key=$(kubectl -n garage exec "$garage_pod" -- garage api key list 2>/dev/null | grep -A1 "admin" | tail -1 | awk '{print $2}' || echo "")
    garage_secret_key=$(kubectl -n garage exec "$garage_pod" -- garage api key list 2>/dev/null | grep -A1 "admin" | tail -1 | awk '{print $3}' || echo "")
  fi
fi

if [[ -z "$garage_access_key" || -z "$garage_secret_key" ]]; then
  log "Warning: Could not retrieve S3 credentials, creating static secret"
  garage_access_key="garage"
  garage_secret_key="garage_secret_key_change_me"
  
  kubectl -n garage create secret generic garage-s3-credentials \
    --from-literal=accesskey="$garage_access_key" \
    --from-literal=secretkey="$garage_secret_key" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  log "Storing S3 credentials in secret"
  kubectl -n garage create secret generic garage-s3-credentials \
    --from-literal=accesskey="$garage_access_key" \
    --from-literal=secretkey="$garage_secret_key" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

log "Creating Garage Service for internal access"
kubectl -n garage expose deployment garage --name=garage-s3 --port=${S3_PORT} --target-port=s3 --dry-run=client -o yaml | kubectl apply -f -

s3_endpoint="garage-s3.garage.svc.cluster.local:${S3_PORT}"

log "Garage S3 installed successfully!"
log "S3 Endpoint (internal): ${s3_endpoint}"
log "S3 Endpoint (external): https://garage.${public_zone_name}"
log "Bucket: nextcloud-data"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg s3_endpoint "$s3_endpoint" \
    --arg bucket "nextcloud-data" \
    --arg access_key "$garage_access_key" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      s3_endpoint: $s3_endpoint,
      bucket: $bucket,
      access_key: $access_key
    }' >"$STEP_RESULT_FILE"
fi

log "Garage S3 installation complete"