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
VELERO_VALUES_TEMPLATE_PATH="${WORKSPACE_ROOT}/gitops/values/velero.yaml"
SEAWEEDFS_ENDPOINT="${SEAWEEDFS_ENDPOINT:-}"
SEAWEEDFS_BUCKET="${SEAWEEDFS_BUCKET:-twinbox-velero}"
SEAWEEDFS_REGION="${SEAWEEDFS_REGION:-seaweedfs}"

export VELERO_SECRET_NAME

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"
command -v node >/dev/null 2>&1 || fail "node not found"

export KUBECONFIG="$KUBECONFIG_FILE"

mkdir -p "$(dirname "$VELERO_SECRET_FILE")"

render_secret_file() {
  local endpoint="$1"
  local bucket="$2"
  local region="$3"
  local username="$4"
  local password="$5"

  jq -n \
    --arg mode "seaweedfs" \
    --arg endpoint "$endpoint" \
    --arg bucket "$bucket" \
    --arg region "$region" \
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

load_velero_settings() {
  local management_ip="${MANAGEMENT_VM_IP:-$(hostname -I | awk '{print $1}')}"
  local endpoint="http://${management_ip}:8333"
  local username="${SEAWEEDFS_ACCESS_KEY_ID:-velero}"
  local password="${SEAWEEDFS_SECRET_ACCESS_KEY:-}"
  local bucket="${SEAWEEDFS_BUCKET:-twinbox-velero}"
  local region="${SEAWEEDFS_REGION:-seaweedfs}"

  if [[ -f "$VELERO_SECRET_FILE" ]]; then
    local file_endpoint=""
    local file_bucket=""
    local file_region=""
    local file_username=""
    local file_password=""

    file_endpoint="$(jq -r '.endpoint // empty' "$VELERO_SECRET_FILE")"
    file_bucket="$(jq -r '.bucket // empty' "$VELERO_SECRET_FILE")"
    file_region="$(jq -r '.region // empty' "$VELERO_SECRET_FILE")"
    file_username="$(jq -r '.username // empty' "$VELERO_SECRET_FILE")"
    file_password="$(jq -r '.password // empty' "$VELERO_SECRET_FILE")"

    if [[ -n "$file_endpoint" && "$file_endpoint" != *"seaweedfs.longhorn-system.svc.cluster.local"* ]]; then
      endpoint="$file_endpoint"
    fi
    [[ -n "$file_bucket" ]] && bucket="$file_bucket"
    [[ -n "$file_region" ]] && region="$file_region"
    [[ -n "$file_username" ]] && username="$file_username"
    [[ -n "$file_password" ]] && password="$file_password"
  fi

  if [[ -z "$password" ]]; then
    password="$(openssl rand -hex 16)"
  fi

  SEAWEEDFS_ENDPOINT="$endpoint"
  SEAWEEDFS_BUCKET="$bucket"
  SEAWEEDFS_REGION="$region"
  VELERO_USERNAME="$username"
  VELERO_PASSWORD="$password"

  export MANAGEMENT_VM_IP="$management_ip"
  export SEAWEEDFS_ENDPOINT SEAWEEDFS_BUCKET SEAWEEDFS_REGION
  export VELERO_USERNAME VELERO_PASSWORD

  render_secret_file "$SEAWEEDFS_ENDPOINT" "$SEAWEEDFS_BUCKET" "$SEAWEEDFS_REGION" "$VELERO_USERNAME" "$VELERO_PASSWORD"
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

render_velero_application_manifest() {
  local rendered_manifest="$1"

  node - "$VELERO_APP_MANIFEST_PATH" "$VELERO_VALUES_TEMPLATE_PATH" "$rendered_manifest" <<'NODE'
const fs = require('fs');

const [manifestPath, valuesTemplatePath, outputPath] = process.argv.slice(2);
const manifestTemplate = fs.readFileSync(manifestPath, 'utf8');
const valuesTemplate = fs.readFileSync(valuesTemplatePath, 'utf8');

const replacements = {
  '__SEAWEEDFS_ENDPOINT__': process.env.SEAWEEDFS_ENDPOINT,
  '__SEAWEEDFS_BUCKET__': process.env.SEAWEEDFS_BUCKET,
  '__SEAWEEDFS_REGION__': process.env.SEAWEEDFS_REGION,
  '__VELERO_SECRET_NAME__': process.env.VELERO_SECRET_NAME,
};

let valuesRendered = valuesTemplate;
for (const [needle, value] of Object.entries(replacements)) {
  valuesRendered = valuesRendered.replaceAll(needle, value);
}
valuesRendered = valuesRendered.replace(/\n+$/, '');
valuesRendered = valuesRendered
  .split('\n')
  .map((line) => `        ${line}`)
  .join('\n');

const manifestRendered = manifestTemplate.replace('__VELERO_VALUES__', valuesRendered);
fs.writeFileSync(outputPath, `${manifestRendered.replace(/\n+$/, '')}\n`, 'utf8');
NODE
}

log "Initializing Velero backup installation"

load_velero_settings

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "velero" \
  --json-file "$VELERO_SECRET_FILE" \
  --required-keys "mode,endpoint,bucket,region,username,password"

kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
create_or_update_secret "$VELERO_SECRET_NAME" "$VELERO_NAMESPACE" "$VELERO_USERNAME" "$VELERO_PASSWORD"

rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/velero-application-XXXXXX.yaml")"
trap 'rm -f "$rendered_manifest"' EXIT
render_velero_application_manifest "$rendered_manifest"

log "Applying Velero against SeaweedFS at ${SEAWEEDFS_ENDPOINT}"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_manifest" \
  --application "velero"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "velero" \
    --arg manifest_path "$VELERO_APP_MANIFEST_PATH" \
    --arg bucket "$SEAWEEDFS_BUCKET" \
    --arg secret_name "$VELERO_SECRET_NAME" \
    --arg namespace "$VELERO_NAMESPACE" \
    --arg mode "seaweedfs" \
    --arg endpoint "$SEAWEEDFS_ENDPOINT" \
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
