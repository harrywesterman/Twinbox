#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
VELERO_SECRET_FILE="${BOOTSTRAP_ROOT}/secrets/global/velero.json"
VELERO_SECRET_NAME="${VELERO_SECRET_NAME:-velero-credentials}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
VELERO_APP_MANIFEST_PATH="${WORKSPACE_ROOT}/gitops/apps/velero.yaml"
SEAWEEDFS_SERVICE_URL="${SEAWEEDFS_SERVICE_URL:-http://seaweedfs.longhorn-system.svc.cluster.local:8333}"
SEAWEEDFS_BUCKET="${SEAWEEDFS_BUCKET:-twinbox-velero}"
SEAWEEDFS_REGION="${SEAWEEDFS_REGION:-seaweedfs}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

export KUBECONFIG="$KUBECONFIG_FILE"

mkdir -p "$(dirname "$VELERO_SECRET_FILE")"

render_secret_file() {
  local username="$1"
  local password="$2"

  jq -n \
    --arg mode "seaweedfs" \
    --arg endpoint "$SEAWEEDFS_SERVICE_URL" \
    --arg bucket "$SEAWEEDFS_BUCKET" \
    --arg region "$SEAWEEDFS_REGION" \
    --arg username "$username" \
    --arg password "$password" \
    '{
      mode: $mode,
      endpoint: $endpoint,
      bucket: $bucket,
      region: $region,
      username: $username,
      password: $password
    }' >"$VELERO_SECRET_FILE"
  chmod 0600 "$VELERO_SECRET_FILE"
}

create_or_update_secret() {
  local secret_name="$1"
  local namespace="$2"
  local access_key_id="$3"
  local secret_access_key="$4"
  local cloud_credentials_file

  cloud_credentials_file="$(mktemp)"
  cat >"$cloud_credentials_file" <<EOF
aws_access_key_id=${access_key_id}
aws_secret_access_key=${secret_access_key}
EOF

  kubectl -n "$namespace" create secret generic "$secret_name" \
    --from-literal=AWS_ACCESS_KEY_ID="$access_key_id" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$secret_access_key" \
    --from-file=cloud="$cloud_credentials_file" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  rm -f "$cloud_credentials_file"
}

log "Initializing Velero backup installation"

existing_username=""
existing_password=""
if [[ -f "$VELERO_SECRET_FILE" ]]; then
  existing_username="$(jq -r '.username // empty' "$VELERO_SECRET_FILE")"
  existing_password="$(jq -r '.password // empty' "$VELERO_SECRET_FILE")"
fi

if [[ -z "$existing_username" || -z "$existing_password" ]]; then
  existing_username="${SEAWEEDFS_ACCESS_KEY_ID:-velero}"
  existing_password="${SEAWEEDFS_SECRET_ACCESS_KEY:-$(openssl rand -hex 16)}"
fi

render_secret_file "$existing_username" "$existing_password"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "velero" \
  --json-file "$VELERO_SECRET_FILE" \
  --required-keys "mode,endpoint,bucket,region,username,password"

kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
create_or_update_secret "$VELERO_SECRET_NAME" "$VELERO_NAMESPACE" "$existing_username" "$existing_password"

log "Applying Velero against SeaweedFS at ${SEAWEEDFS_SERVICE_URL}"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$VELERO_APP_MANIFEST_PATH" \
  --application "velero"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "velero" \
    --arg manifest_path "$VELERO_APP_MANIFEST_PATH" \
    --arg bucket "$SEAWEEDFS_BUCKET" \
    --arg secret_name "$VELERO_SECRET_NAME" \
    --arg namespace "$VELERO_NAMESPACE" \
    --arg mode "seaweedfs" \
    --arg endpoint "$SEAWEEDFS_SERVICE_URL" \
    '{
      application: $application,
      manifest_path: $manifest_path,
      bucket: $bucket,
      secret_name: $secret_name,
      namespace: $namespace,
      mode: $mode,
      endpoint: $endpoint
    }' >"$STEP_RESULT_FILE"
fi
