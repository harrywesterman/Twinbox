#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
[[ -n "${STEP_INPUTS_JSON:-}" ]] || fail "STEP_INPUTS_JSON is required"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
VELERO_SECRET_FILE="$BOOTSTRAP_ROOT/secrets/global/velero.json"
VELERO_SECRET_NAME="${VELERO_SECRET_NAME:-velero-credentials}"
GARAGE_BOOTSTRAP_SECRET_NAME="${GARAGE_BOOTSTRAP_SECRET_NAME:-garage-bootstrap}"
GARAGE_KEY_NAME="${GARAGE_KEY_NAME:-velero-backup}"
VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
GARAGE_APP_MANIFEST_PATH="$WORKSPACE_ROOT/gitops/apps/garage.yaml"
VELERO_APP_MANIFEST_PATH="$WORKSPACE_ROOT/gitops/apps/velero.yaml"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

export KUBECONFIG="$KUBECONFIG_FILE"

inputs_json="$(printf '%s' "$STEP_INPUTS_JSON" | jq -c '.')"
use_external_s3="$(jq -r '.use_external_s3 // false' <<<"$inputs_json")"
s3_endpoint="$(jq -r '.s3_endpoint // empty' <<<"$inputs_json")"
s3_bucket="$(jq -r '.s3_bucket // "twinbox-velero"' <<<"$inputs_json")"
s3_region="$(jq -r '.s3_region // "garage"' <<<"$inputs_json")"
s3_access_key_id="$(jq -r '.s3_access_key_id // empty' <<<"$inputs_json")"
s3_secret_access_key="$(jq -r '.s3_secret_access_key // empty' <<<"$inputs_json")"

mkdir -p "$(dirname "$VELERO_SECRET_FILE")"

render_secret_file() {
  local username="$1"
  local password="$2"
  local endpoint="$3"
  local mode="$4"
  local bucket="$5"
  local region="$6"

  local tmp_file
  tmp_file="$(mktemp)"
  jq -n \
    --arg mode "$mode" \
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
    }' >"$tmp_file"
  install -m 600 "$tmp_file" "$VELERO_SECRET_FILE"
  rm -f "$tmp_file"
}

render_external_manifest() {
  local manifest_file="$1"
  local bucket="$2"
  local endpoint="$3"
  local region="$4"

  cat >"$manifest_file" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://vmware-tanzu.github.io/helm-charts
      chart: velero
      targetRevision: "12.0.0"
      helm:
        values: |
          credentials:
            useSecret: true
            existingSecret: velero-credentials
          configuration:
            defaultBackupStorageLocation: default
            backupStorageLocation:
              - name: default
                provider: aws
                bucket: ${bucket}
                default: true
                credential:
                  name: velero-credentials
                  key: cloud
                config:
                  region: ${region}
                  s3ForcePathStyle: true
                  s3Url: ${endpoint}
          snapshotsEnabled: false
          defaultVolumesToFsBackup: true
          deployNodeAgent: true
          initContainers:
            - name: velero-plugin-for-aws
              image: velero/velero-plugin-for-aws:v1.13.1
              imagePullPolicy: IfNotPresent
              volumeMounts:
                - mountPath: /target
                  name: plugins
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/enforce-version: latest
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/audit-version: latest
        pod-security.kubernetes.io/warn: privileged
        pod-security.kubernetes.io/warn-version: latest
    syncOptions:
      - CreateNamespace=true
EOF
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

create_or_update_garage_bootstrap_secret() {
  local secret_name="$1"
  local namespace="$2"
  local rpc_secret="$3"
  local admin_token="$4"
  local metrics_token="$5"
  local config_file="$6"

  kubectl -n "$namespace" create secret generic "$secret_name" \
    --from-literal=GARAGE_RPC_SECRET="$rpc_secret" \
    --from-literal=GARAGE_ADMIN_TOKEN="$admin_token" \
    --from-literal=GARAGE_METRICS_TOKEN="$metrics_token" \
    --from-file=garage.toml="$config_file" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_for_garage_deployment() {
  local namespace="$1"
  local deployment_name="$2"

  local attempt=1
  local attempts=120
  while true; do
    if kubectl -n "$namespace" get deployment "$deployment_name" >/dev/null 2>&1; then
      break
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for deployment/${deployment_name} to appear in namespace/${namespace}"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done

  kubectl -n "$namespace" rollout status deployment/"$deployment_name" --timeout=10m
}

initialize_garage() {
  local namespace="$1"
  local bucket_name="$2"
  local key_name="$3"
  local zone_name="$4"
  local capacity="$5"

  if [[ -f "$VELERO_SECRET_FILE" ]]; then
    local existing_mode existing_username existing_password existing_bucket existing_region
    existing_mode="$(jq -r '.mode // empty' "$VELERO_SECRET_FILE")"
    existing_username="$(jq -r '.username // empty' "$VELERO_SECRET_FILE")"
    existing_password="$(jq -r '.password // empty' "$VELERO_SECRET_FILE")"
    existing_bucket="$(jq -r '.bucket // empty' "$VELERO_SECRET_FILE")"
    existing_region="$(jq -r '.region // empty' "$VELERO_SECRET_FILE")"
    if [[ "$existing_mode" == "embedded-garage" && -n "$existing_username" && -n "$existing_password" && "$existing_bucket" == "$bucket_name" && "$existing_region" == "garage" ]]; then
      log "Reusing stored Garage credentials for Velero"
      render_secret_file "$existing_username" "$existing_password" \
        "http://garage.velero.svc.cluster.local:3900" "embedded-garage" "$bucket_name" "garage"
      create_or_update_secret "$VELERO_SECRET_NAME" "$namespace" "$existing_username" "$existing_password"
      return 0
    fi
  fi

  local node_id
  node_id="$(
    kubectl -n "$namespace" exec deployment/garage -- sh -lc 'garage node id' \
      | awk 'NR == 1 { print $1 }'
  )"
  [[ -n "$node_id" ]] || fail "Garage node id could not be determined"

  log "Configuring Garage layout for node ${node_id}"
  kubectl -n "$namespace" exec deployment/garage -- sh -lc \
    "garage layout assign ${node_id} -z ${zone_name} -c ${capacity}" >/dev/null
  kubectl -n "$namespace" exec deployment/garage -- sh -lc \
    "garage layout apply --version 1" >/dev/null

  log "Ensuring Garage bucket ${bucket_name}"
  kubectl -n "$namespace" exec deployment/garage -- sh -lc \
    "garage bucket create ${bucket_name}" >/dev/null 2>&1 || true

  log "Creating Garage key ${key_name}"
  local key_output
  key_output="$(
    kubectl -n "$namespace" exec deployment/garage -- sh -lc \
      "garage key create ${key_name}"
  )"

  garage_access_key_id="$(awk -F': ' '/^Key ID:/ { print $2; exit }' <<<"$key_output")"
  garage_secret_access_key="$(awk -F': ' '/^Secret key:/ { print $2; exit }' <<<"$key_output")"
  [[ -n "$garage_access_key_id" ]] || fail "Garage key ID was not returned"
  [[ -n "$garage_secret_access_key" ]] || fail "Garage secret key was not returned"

  kubectl -n "$namespace" exec deployment/garage -- sh -lc \
    "garage bucket allow --read --write --owner ${bucket_name} --key ${key_name}" >/dev/null

  render_secret_file "$garage_access_key_id" "$garage_secret_access_key" \
    "http://garage.velero.svc.cluster.local:3900" "embedded-garage" "$bucket_name" "garage"
  create_or_update_secret "$VELERO_SECRET_NAME" "$namespace" "$garage_access_key_id" "$garage_secret_access_key"
}

log "Initializing Velero backup installation"

if [[ "$use_external_s3" == "true" ]]; then
  [[ -n "$s3_endpoint" ]] || fail "s3_endpoint is required when use_external_s3 is true"
  [[ -n "$s3_bucket" ]] || fail "s3_bucket is required when use_external_s3 is true"
  [[ -n "$s3_access_key_id" ]] || fail "s3_access_key_id is required when use_external_s3 is true"
  [[ -n "$s3_secret_access_key" ]] || fail "s3_secret_access_key is required when use_external_s3 is true"

  render_secret_file "$s3_access_key_id" "$s3_secret_access_key" "$s3_endpoint" \
    "external-s3" "$s3_bucket" "$s3_region"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "velero" \
    --json-file "$VELERO_SECRET_FILE" \
    --required-keys "mode,endpoint,bucket,region,username,password"
  kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  create_or_update_secret "$VELERO_SECRET_NAME" "$VELERO_NAMESPACE" "$s3_access_key_id" "$s3_secret_access_key"

  external_manifest_file="$(mktemp)"
  render_external_manifest "$external_manifest_file" "$s3_bucket" "$s3_endpoint" "$s3_region"

  log "Installing Velero with external S3 target ${s3_endpoint}"
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$external_manifest_file" \
    --application "velero"
  rm -f "$external_manifest_file"
else
  garage_rpc_secret="${GARAGE_RPC_SECRET:-$(openssl rand -hex 32)}"
  garage_admin_token="${GARAGE_ADMIN_TOKEN:-$(openssl rand -hex 32)}"
  garage_metrics_token="${GARAGE_METRICS_TOKEN:-$(openssl rand -hex 32)}"
  garage_zone="${GARAGE_ZONE:-local}"
  garage_capacity="${GARAGE_CAPACITY:-20G}"

  garage_config_file="$(mktemp)"

  cat >"$garage_config_file" <<EOF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "localhost:3901"
rpc_secret = "${garage_rpc_secret}"

[s3_api]
api_bind_addr = "[::]:3900"
s3_region = "garage"

[admin]
api_bind_addr = "[::]:3903"
admin_token = "${garage_admin_token}"
metrics_token = "${garage_metrics_token}"
metrics_require_token = true
EOF

  kubectl create namespace "$VELERO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  create_or_update_garage_bootstrap_secret \
    "$GARAGE_BOOTSTRAP_SECRET_NAME" \
    "$VELERO_NAMESPACE" \
    "$garage_rpc_secret" \
    "$garage_admin_token" \
    "$garage_metrics_token" \
    "$garage_config_file"

  log "Installing Garage as the built-in S3 target"
  kubectl apply --validate=false -f "$GARAGE_APP_MANIFEST_PATH" >/dev/null
  wait_for_garage_deployment "$VELERO_NAMESPACE" "garage"
  initialize_garage "$VELERO_NAMESPACE" "$s3_bucket" "$GARAGE_KEY_NAME" "$garage_zone" "$garage_capacity"
  rm -f "$garage_config_file"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "velero" \
    --json-file "$VELERO_SECRET_FILE" \
    --required-keys "mode,endpoint,bucket,region,username,password"

  log "Applying Velero after Garage bootstrap"
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$VELERO_APP_MANIFEST_PATH" \
    --application "velero"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "velero" \
    --arg manifest_path "$VELERO_APP_MANIFEST_PATH" \
    --arg bucket "$s3_bucket" \
    --arg secret_name "$VELERO_SECRET_NAME" \
    --arg namespace "$VELERO_NAMESPACE" \
    --arg mode "$( [[ "$use_external_s3" == "true" ]] && printf 'external-s3' || printf 'embedded-garage' )" \
    --arg endpoint "$(jq -r '.endpoint // empty' "$VELERO_SECRET_FILE")" \
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
