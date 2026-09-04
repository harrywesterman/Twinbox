#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
SEAWEEDFS_NAMESPACE="${SEAWEEDFS_NAMESPACE:-seaweedfs}"
SEAWEEDFS_APP_NAME="${SEAWEEDFS_APP_NAME:-seaweedfs-object-store}"
SEAWEEDFS_APP_S3_ENDPOINT="${SEAWEEDFS_APP_S3_ENDPOINT:-http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333}"
SEAWEEDFS_APP_REGION="${SEAWEEDFS_APP_REGION:-seaweedfs}"
SEAWEEDFS_MASTODON_BUCKET="${SEAWEEDFS_MASTODON_BUCKET:-mastodon}"
SEAWEEDFS_MASTODON_USERNAME="${SEAWEEDFS_MASTODON_USERNAME:-mastodon}"
SEAWEEDFS_MASTODON_SECRET_PATH="${SEAWEEDFS_MASTODON_SECRET_PATH:-twinbox/apps/mastodon/s3}"

# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

generate_s3_secret_key() {
  openssl rand -hex 24
}

wait_for_resource() {
  local resource="$1"
  local label="$2"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$SEAWEEDFS_NAMESPACE" get "$resource" >/dev/null 2>&1; then
      log "${label} exists"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not appear after ${attempts} attempts"
    fi

    log "Waiting for ${label} (${attempt}/${attempts})"
    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_rollout() {
  local resource="$1"
  local label="$2"

  wait_for_resource "$resource" "$label"
  kubectl -n "$SEAWEEDFS_NAMESPACE" rollout status "$resource" --timeout=10m
}

wait_for_s3_shell() {
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$SEAWEEDFS_NAMESPACE" exec deployment/seaweedfs-s3 -- \
      sh -lc 'printf "s3.config.show\n" | weed shell -master=seaweedfs-master-0.seaweedfs-master.seaweedfs:9333' >/dev/null 2>&1; then
      log "SeaweedFS S3 shell is ready"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "SeaweedFS S3 shell never became ready"
    fi

    log "Waiting for SeaweedFS S3 shell (${attempt}/${attempts})"
    sleep 5
    attempt=$((attempt + 1))
  done
}

run_weed_shell() {
  local command="$1"

  kubectl -n "$SEAWEEDFS_NAMESPACE" exec deployment/seaweedfs-s3 -- \
    sh -lc "printf '%s\n' \"$command\" | weed shell -master=seaweedfs-master-0.seaweedfs-master.seaweedfs:9333"
}

sync_mastodon_s3_secret() {
  local secret_file
  local existing_json=""
  local access_key="$SEAWEEDFS_MASTODON_USERNAME"
  local secret_key=""

  if existing_json="$(openbao_read_secret_json "$SEAWEEDFS_MASTODON_SECRET_PATH" 2>/dev/null || true)"; then
    secret_key="$(jq -r '.AWS_SECRET_ACCESS_KEY // .secret_key // empty' <<<"$existing_json")"
  fi

  if [[ -z "$secret_key" ]]; then
    secret_key="$(generate_s3_secret_key)"
  fi

  secret_file="$(mktemp "${TMPDIR:-/tmp}/mastodon-s3-XXXXXX.json")"
  trap 'rm -f "$secret_file"' RETURN
  jq -n \
    --arg access_key "$access_key" \
    --arg secret_key "$secret_key" \
    --arg bucket "$SEAWEEDFS_MASTODON_BUCKET" \
    --arg endpoint "$SEAWEEDFS_APP_S3_ENDPOINT" \
    --arg region "$SEAWEEDFS_APP_REGION" \
    '{
      AWS_ACCESS_KEY_ID: $access_key,
      AWS_SECRET_ACCESS_KEY: $secret_key,
      bucket: $bucket,
      endpoint: $endpoint,
      region: $region
    }' >"$secret_file"
  chmod 0600 "$secret_file"

  log "Writing Mastodon app-media S3 secret to OpenBao"
  openbao_sync_secret_file "$SEAWEEDFS_MASTODON_SECRET_PATH" "$secret_file" \
    "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "bucket" "endpoint" "region"

  SEAWEEDFS_MASTODON_SECRET_KEY="$secret_key"
  export SEAWEEDFS_MASTODON_SECRET_KEY
}

configure_mastodon_bucket() {
  log "Configuring SeaweedFS IAM user ${SEAWEEDFS_MASTODON_USERNAME}"
  run_weed_shell "s3.configure --user ${SEAWEEDFS_MASTODON_USERNAME} --access_key ${SEAWEEDFS_MASTODON_USERNAME} --secret_key ${SEAWEEDFS_MASTODON_SECRET_KEY} --buckets ${SEAWEEDFS_MASTODON_BUCKET} --actions Read,Write,List,Tagging --apply true" >/dev/null

  local bucket_list=""
  bucket_list="$(run_weed_shell "s3.bucket.list" || true)"
  if ! grep -Eq "^[[:space:]]+${SEAWEEDFS_MASTODON_BUCKET}[[:space:]]" <<<"$bucket_list"; then
    log "Creating SeaweedFS bucket ${SEAWEEDFS_MASTODON_BUCKET}"
    run_weed_shell "s3.bucket.create -name ${SEAWEEDFS_MASTODON_BUCKET} -owner ${SEAWEEDFS_MASTODON_USERNAME}" >/dev/null
  else
    log "SeaweedFS bucket ${SEAWEEDFS_MASTODON_BUCKET} already exists"
  fi
}

[[ -f "$KUBECONFIG_FILE" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE}"

require_cmd kubectl
require_cmd jq
require_cmd openssl

export KUBECONFIG="$KUBECONFIG_FILE"

log "Installing Kubernetes SeaweedFS object store for app media"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/seaweedfs-object-store.yaml" \
  --application "$SEAWEEDFS_APP_NAME" \
  --destination-namespace "$SEAWEEDFS_NAMESPACE"

wait_for_rollout "statefulset/seaweedfs-master" "SeaweedFS master"
wait_for_rollout "statefulset/seaweedfs-volume" "SeaweedFS volume"
wait_for_rollout "statefulset/seaweedfs-filer" "SeaweedFS filer"
wait_for_rollout "deployment/seaweedfs-s3" "SeaweedFS S3 gateway"
wait_for_rollout "statefulset/seaweedfs-admin" "SeaweedFS admin"
wait_for_s3_shell
sync_mastodon_s3_secret
configure_mastodon_bucket

log "Refreshing platform-ingress for s3 and s3-admin routes"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
  --application "platform-ingress" \
  --no-wait

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "$SEAWEEDFS_APP_NAME" \
    --arg namespace "$SEAWEEDFS_NAMESPACE" \
    --arg endpoint "$SEAWEEDFS_APP_S3_ENDPOINT" \
    --arg mastodon_bucket "$SEAWEEDFS_MASTODON_BUCKET" \
    --arg mastodon_secret_path "$SEAWEEDFS_MASTODON_SECRET_PATH" \
    '{
      application: $application,
      namespace: $namespace,
      endpoint: $endpoint,
      mastodon_bucket: $mastodon_bucket,
      mastodon_secret_path: $mastodon_secret_path
    }' >"$STEP_RESULT_FILE"
fi
