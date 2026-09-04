#!/usr/bin/env bash

backup_storage_fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; return 1; }

load_backup_storage_profile() {
  local purpose="$1"
  local cluster_id="${TWINBOX_CLUSTER_ID:-}"
  local bootstrap_root="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
  local profile_file="${BACKUP_STORAGE_PROFILE_FILE:-${bootstrap_root}/secrets/cluster/${cluster_id}/backup-storage/metadata.json}"

  [[ -n "$cluster_id" ]] || backup_storage_fail "TWINBOX_CLUSTER_ID is required"
  [[ -f "$profile_file" ]] || backup_storage_fail "backup storage profile not found at ${profile_file}"
  jq -e '.endpoint and .region and .access_key_id and .secret_access_key and .buckets' "$profile_file" >/dev/null \
    || backup_storage_fail "backup storage profile is incomplete"

  BACKUP_S3_MODE="$(jq -r '.mode' "$profile_file")"
  BACKUP_S3_ENDPOINT="$(jq -r '.endpoint' "$profile_file")"
  BACKUP_S3_REGION="$(jq -r '.region' "$profile_file")"
  BACKUP_S3_PATH_STYLE="$(jq -r '.path_style // true' "$profile_file")"
  BACKUP_S3_ACCESS_KEY_ID="$(jq -r '.access_key_id' "$profile_file")"
  BACKUP_S3_SECRET_ACCESS_KEY="$(jq -r '.secret_access_key' "$profile_file")"
  BACKUP_S3_BUCKET="$(jq -r --arg purpose "$purpose" '.buckets[$purpose] // empty' "$profile_file")"
  BACKUP_S3_CA_FILE="$(jq -r '.tls.ca_file // empty' "$profile_file")"
  [[ -n "$BACKUP_S3_BUCKET" ]] || backup_storage_fail "backup bucket for ${purpose} is missing"

  export BACKUP_S3_MODE BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_PATH_STYLE
  export BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_BUCKET
  export BACKUP_S3_CA_FILE
}
