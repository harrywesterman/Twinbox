#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-storage-profile.sh"

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
VELERO_SECRET_NAME="${VELERO_SECRET_NAME:-velero-credentials}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
VELERO_APP_MANIFEST_PATH="${WORKSPACE_ROOT}/gitops/apps/velero.yaml"
VELERO_VALUES_TEMPLATE_PATH="${WORKSPACE_ROOT}/gitops/values/velero.yaml"

export VELERO_SECRET_NAME

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"
command -v node >/dev/null 2>&1 || fail "node not found"

export KUBECONFIG="$KUBECONFIG_FILE"

load_velero_settings() {
  load_backup_storage_profile velero
  VELERO_USERNAME="$BACKUP_S3_ACCESS_KEY_ID"
  VELERO_PASSWORD="$BACKUP_S3_SECRET_ACCESS_KEY"
  if [[ -n "$BACKUP_S3_CA_FILE" && -f "$BACKUP_S3_CA_FILE" ]]; then
    BACKUP_S3_CA_CERT="$(base64 <"$BACKUP_S3_CA_FILE" | tr -d '\n')"
  else
    BACKUP_S3_CA_CERT=""
  fi
  export VELERO_USERNAME VELERO_PASSWORD
  export BACKUP_S3_CA_CERT
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
  '__BACKUP_S3_ENDPOINT__': process.env.BACKUP_S3_ENDPOINT,
  '__BACKUP_S3_BUCKET__': process.env.BACKUP_S3_BUCKET,
  '__BACKUP_S3_REGION__': process.env.BACKUP_S3_REGION,
  '__BACKUP_S3_PATH_STYLE__': process.env.BACKUP_S3_PATH_STYLE,
  '__VELERO_SECRET_NAME__': process.env.VELERO_SECRET_NAME,
  '__BACKUP_S3_CA_CERT__': process.env.BACKUP_S3_CA_CERT,
};

let valuesRendered = valuesTemplate;
for (const [needle, value] of Object.entries(replacements)) {
  valuesRendered = valuesRendered.replaceAll(needle, value);
}
if (!process.env.BACKUP_S3_CA_CERT) {
  valuesRendered = valuesRendered.replace(/^\s*caCert:\s*\n/m, '');
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

kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
create_or_update_secret "$VELERO_SECRET_NAME" "$VELERO_NAMESPACE" "$VELERO_USERNAME" "$VELERO_PASSWORD"

rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/velero-application-XXXXXX")"
trap 'rm -f "$rendered_manifest"' EXIT
render_velero_application_manifest "$rendered_manifest"

log "Applying Velero against configured S3 backup storage"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_manifest" \
  --application "velero"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "velero" \
    --arg manifest_path "$VELERO_APP_MANIFEST_PATH" \
    --arg bucket "$BACKUP_S3_BUCKET" \
    --arg secret_name "$VELERO_SECRET_NAME" \
    --arg namespace "$VELERO_NAMESPACE" \
    --arg mode "$BACKUP_S3_MODE" \
    --arg endpoint "$BACKUP_S3_ENDPOINT" \
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
