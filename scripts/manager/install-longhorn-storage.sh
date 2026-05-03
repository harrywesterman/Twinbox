#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_storage_class() {
  local storage_class="${LONGHORN_STORAGE_CLASS:-longhorn}"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
      log "StorageClass/${storage_class} is available"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "StorageClass/${storage_class} did not become available after ${attempts} attempts"
    fi

    log "Waiting for StorageClass/${storage_class} to appear"
    sleep 5
    attempt=$((attempt + 1))
  done
}

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

load_longhorn_backup_settings() {
  local management_ip="${MANAGEMENT_VM_IP:-$(hostname -I | awk '{print $1}')}"
  local endpoint="http://${management_ip}:8333"
  local bucket="${SEAWEEDFS_BUCKET:-twinbox-velero}"
  local region="${SEAWEEDFS_REGION:-seaweedfs}"
  local username="${SEAWEEDFS_ACCESS_KEY_ID:-velero}"
  local password="${SEAWEEDFS_SECRET_ACCESS_KEY:-}"
  local file_value=""

  if [[ -f "$VELERO_SECRET_FILE" ]]; then
    file_value="$(jq -r '.endpoint // empty' "$VELERO_SECRET_FILE")"
    [[ -n "$file_value" ]] && endpoint="$file_value"
    file_value="$(jq -r '.bucket // empty' "$VELERO_SECRET_FILE")"
    [[ -n "$file_value" ]] && bucket="$file_value"
    file_value="$(jq -r '.region // empty' "$VELERO_SECRET_FILE")"
    [[ -n "$file_value" ]] && region="$file_value"
    file_value="$(jq -r '.username // empty' "$VELERO_SECRET_FILE")"
    [[ -n "$file_value" ]] && username="$file_value"
    file_value="$(jq -r '.password // empty' "$VELERO_SECRET_FILE")"
    [[ -n "$file_value" ]] && password="$file_value"
  fi

  if [[ -z "$password" ]]; then
    password="$(openssl rand -hex 16)"
  fi

  SEAWEEDFS_ENDPOINT="$endpoint"
  SEAWEEDFS_BUCKET="$bucket"
  SEAWEEDFS_REGION="$region"
  LONGHORN_BACKUP_USERNAME="$username"
  LONGHORN_BACKUP_PASSWORD="$password"
  LONGHORN_BACKUP_TARGET="s3://${SEAWEEDFS_BUCKET}@${SEAWEEDFS_REGION}/"

  export SEAWEEDFS_ENDPOINT SEAWEEDFS_BUCKET SEAWEEDFS_REGION
  export LONGHORN_BACKUP_USERNAME LONGHORN_BACKUP_PASSWORD LONGHORN_BACKUP_TARGET

  mkdir -p "$(dirname "$VELERO_SECRET_FILE")"
  render_secret_file "$SEAWEEDFS_ENDPOINT" "$SEAWEEDFS_BUCKET" "$SEAWEEDFS_REGION" "$LONGHORN_BACKUP_USERNAME" "$LONGHORN_BACKUP_PASSWORD"
}

create_or_update_longhorn_backup_secret() {
  kubectl create namespace "$LONGHORN_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$LONGHORN_NAMESPACE" create secret generic "$LONGHORN_BACKUP_SECRET_NAME" \
    --from-literal=AWS_ACCESS_KEY_ID="$LONGHORN_BACKUP_USERNAME" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$LONGHORN_BACKUP_PASSWORD" \
    --from-literal=AWS_ENDPOINTS="$SEAWEEDFS_ENDPOINT" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

render_longhorn_application_manifest() {
  local rendered_manifest="$1"

  node - "$manifest_path" "$LONGHORN_VALUES_TEMPLATE_PATH" "$rendered_manifest" <<'NODE'
const fs = require('fs');

const [manifestPath, valuesTemplatePath, outputPath] = process.argv.slice(2);
const manifestTemplate = fs.readFileSync(manifestPath, 'utf8');
const valuesTemplate = fs.readFileSync(valuesTemplatePath, 'utf8');

const replacements = {
  '__LONGHORN_BACKUP_TARGET__': process.env.LONGHORN_BACKUP_TARGET,
  '__LONGHORN_BACKUP_SECRET_NAME__': process.env.LONGHORN_BACKUP_SECRET_NAME,
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

const manifestRendered = manifestTemplate.replace('__LONGHORN_VALUES__', valuesRendered);
fs.writeFileSync(outputPath, `${manifestRendered.replace(/\n+$/, '')}\n`, 'utf8');
NODE
}

apply_longhorn_recurring_jobs() {
  log "Applying Longhorn recurring backup jobs"
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: twinbox-snapshot-4h
  namespace: longhorn-system
spec:
  cron: "0 */4 * * *"
  task: snapshot
  groups:
    - default
  retain: 6
  concurrency: 1
---
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: twinbox-backup-daily
  namespace: longhorn-system
spec:
  cron: "0 1 * * *"
  task: backup
  groups:
    - default
  retain: 14
  concurrency: 1
EOF
}

make_storage_class_default() {
  local storage_class="${LONGHORN_STORAGE_CLASS:-longhorn}"
  local default_annotation="storageclass.kubernetes.io/is-default-class"
  local beta_default_annotation="storageclass.beta.kubernetes.io/is-default-class"
  local default_storage_classes
  local default_storage_class
  local storage_class_json

  default_storage_classes="$(
    kubectl get storageclass -o json | jq -r --arg storage_class "$storage_class" '
      .items[]
      | select(.metadata.name != $storage_class)
      | select(
          (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
          or (.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")
        )
      | .metadata.name
    '
  )"

  for default_storage_class in $default_storage_classes; do
    log "Removing default annotation from StorageClass/${default_storage_class}"
    kubectl annotate storageclass "$default_storage_class" \
      "$default_annotation=false" \
      "$beta_default_annotation=false" \
      --overwrite
  done

  log "Marking StorageClass/${storage_class} as the default storage class"
  kubectl annotate storageclass "$storage_class" \
    "$default_annotation=true" \
    "$beta_default_annotation=true" \
    --overwrite

  storage_class_json="$(kubectl get storageclass "$storage_class" -o json)"
  if ! jq -e --arg default_annotation "$default_annotation" --arg beta_default_annotation "$beta_default_annotation" '
    (.metadata.annotations[$default_annotation] == "true")
    or (.metadata.annotations[$beta_default_annotation] == "true")
  ' <<<"$storage_class_json" >/dev/null; then
    fail "StorageClass/${storage_class} was not marked as the default storage class"
  fi

  default_storage_classes="$(
    kubectl get storageclass -o json | jq -r '
      .items[]
      | select(
          (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
          or (.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true")
        )
      | .metadata.name
    '
  )"

  if [[ "$default_storage_classes" != "$storage_class" ]]; then
    fail "StorageClass/${storage_class} is not the only default storage class; found: ${default_storage_classes//$'\n'/, }"
  fi
}

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
VELERO_SECRET_FILE="${BOOTSTRAP_ROOT}/secrets/global/velero.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/longhorn.yaml"
LONGHORN_VALUES_TEMPLATE_PATH="${WORKSPACE_ROOT}/gitops/values/longhorn.yaml"
LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-longhorn-system}"
LONGHORN_BACKUP_SECRET_NAME="${LONGHORN_BACKUP_SECRET_NAME:-longhorn-seaweedfs-backup}"
cluster_id="${TWINBOX_CLUSTER_ID:-}"
cluster_instance_id="${TWINBOX_CLUSTER_INSTANCE_ID:-}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"
command -v node >/dev/null 2>&1 || fail "node not found"

export KUBECONFIG="$KUBECONFIG_FILE"
export LONGHORN_BACKUP_SECRET_NAME

if [[ -n "${KUBE_API_SERVER:-}" ]]; then
  kube_cluster_name="$(kubectl config view --kubeconfig "$KUBECONFIG_FILE" -o jsonpath='{.clusters[0].name}')"
  [[ -n "$kube_cluster_name" ]] || fail "Unable to read cluster name from kubeconfig"
  log "Rewriting kubeconfig cluster ${kube_cluster_name} to ${KUBE_API_SERVER}"
  kubectl config set-cluster "$kube_cluster_name" --kubeconfig "$KUBECONFIG_FILE" --server "$KUBE_API_SERVER" >/dev/null
fi

load_longhorn_backup_settings
create_or_update_longhorn_backup_secret
rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/longhorn-application.XXXXXX.yaml")"
trap 'rm -f "$rendered_manifest"' EXIT
render_longhorn_application_manifest "$rendered_manifest"

log "Installing Longhorn through Argo CD"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_manifest" \
  --application "longhorn"
wait_for_storage_class
make_storage_class_default
apply_longhorn_recurring_jobs

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$cluster_instance_id" \
    --arg application "longhorn" \
    --arg manifest_path "$manifest_path" \
    --arg storage_class "$(printf '%s' "${LONGHORN_STORAGE_CLASS:-longhorn}")" \
    --arg backup_target "$LONGHORN_BACKUP_TARGET" \
    --arg backup_secret "$LONGHORN_BACKUP_SECRET_NAME" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      application: $application,
      manifest_path: $manifest_path,
      storage_class: $storage_class,
      backup_target: $backup_target,
      backup_secret: $backup_secret,
      install_mode: "argocd"
    }' >"$STEP_RESULT_FILE"
fi
