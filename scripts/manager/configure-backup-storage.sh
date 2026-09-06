#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || fail "aws CLI not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-bucket-name.sh"

cluster_id="${TWINBOX_CLUSTER_ID:-$(jq -r '.cluster.id // empty' <<<"$STEP_CONTEXT_JSON")}"
cluster_slug="$(jq -r '.cluster.slug // .cluster.id // empty' <<<"$STEP_CONTEXT_JSON" | tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
mode="$(jq -r '.backup_storage_mode // empty' <<<"$STEP_INPUTS_JSON")"
endpoint="$(jq -r '.s3_endpoint // empty' <<<"$STEP_INPUTS_JSON")"
region="$(jq -r '.s3_region // "us-east-1"' <<<"$STEP_INPUTS_JSON")"
path_style="$(jq -r '.s3_path_style // true' <<<"$STEP_INPUTS_JSON")"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
profile_file="${BOOTSTRAP_ROOT}/secrets/cluster/${cluster_id}/backup-storage/metadata.json"

[[ -n "$cluster_id" ]] || fail "cluster id is required"
[[ -n "$cluster_slug" ]] || fail "cluster slug is required"
[[ "$mode" == "external-s3" || "$mode" == "managed-seaweedfs" ]] || fail "unsupported backup storage mode"
configured_mode="$(jq -r '.mode // empty' "$profile_file" 2>/dev/null || true)"
[[ -z "$configured_mode" || "$configured_mode" == "$mode" ]] || fail "Refusing to change an existing backup storage mode implicitly"

if [[ "$mode" == "managed-seaweedfs" ]]; then
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provision-seaweedfs-backup-vm.sh"
  TWINBOX_CLUSTER_ID="$cluster_id" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure-seaweedfs-admin.sh"
  profile_file="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/cluster/${cluster_id}/backup-storage/metadata.json"
  endpoint="$(jq -r '.endpoint' "$profile_file")"
  region="$(jq -r '.region' "$profile_file")"
  path_style="$(jq -r '.path_style // true' "$profile_file")"
  BACKUP_S3_ACCESS_KEY_ID="$(jq -r '.access_key_id' "$profile_file")"
  BACKUP_S3_SECRET_ACCESS_KEY="$(jq -r '.secret_access_key' "$profile_file")"
  AWS_CA_BUNDLE="$(jq -r '.tls.ca_file // empty' "$profile_file")"
  export AWS_CA_BUNDLE
fi

[[ "$endpoint" == https://* ]] || fail "S3 endpoint must use HTTPS"
[[ -n "$region" ]] || fail "S3 region is required"
[[ -n "${BACKUP_S3_ACCESS_KEY_ID:-}" ]] || fail "S3 access key ID is required"
[[ -n "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ]] || fail "S3 secret access key is required"

database_bucket="$(twinbox_backup_bucket_name "$cluster_slug" databases)"
longhorn_bucket="$(twinbox_backup_bucket_name "$cluster_slug" longhorn)"
velero_bucket="$(twinbox_backup_bucket_name "$cluster_slug" velero)"
management_bucket="$(twinbox_backup_bucket_name "$cluster_slug" management)"
pbs_bucket="$(twinbox_backup_bucket_name "$cluster_slug" pbs)"

aws_args=(--endpoint-url "$endpoint" --region "$region")
export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY"
export AWS_EC2_METADATA_DISABLED=true

ensure_bucket() {
  local bucket="$1"
  if ! aws "${aws_args[@]}" s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    log "Creating backup bucket ${bucket}"
    for attempt in $(seq 1 24); do
      aws "${aws_args[@]}" s3api create-bucket --bucket "$bucket" >/dev/null 2>&1 && return 0
      aws "${aws_args[@]}" s3api create-bucket --bucket "$bucket" \
        --create-bucket-configuration "LocationConstraint=${region}" >/dev/null 2>&1 && return 0
      [[ "$attempt" -lt 24 ]] || fail "Could not create or access backup bucket ${bucket}"
      log "S3 endpoint is not ready for ${bucket} yet (attempt ${attempt}/24)"
      sleep 5
    done
  fi
}

test_bucket() {
  local bucket="$1"
  local key=".twinbox-validation/${cluster_id}-$$"
  local body
  local downloaded
  body="$(mktemp "${TMPDIR:-/tmp}/twinbox-s3-validation-XXXXXX")"
  downloaded="${body}.downloaded"
  printf 'twinbox backup storage validation\n' >"$body"
  aws "${aws_args[@]}" s3api put-object --bucket "$bucket" --key "$key" --body "$body" >/dev/null
  aws "${aws_args[@]}" s3api head-object --bucket "$bucket" --key "$key" >/dev/null
  aws "${aws_args[@]}" s3api get-object --bucket "$bucket" --key "$key" "$downloaded" >/dev/null
  cmp -s "$body" "$downloaded" || fail "S3 object read validation failed for bucket ${bucket}"
  aws "${aws_args[@]}" s3api delete-object --bucket "$bucket" --key "$key" >/dev/null
  rm -f "$body" "$downloaded"
}

for bucket in "$database_bucket" "$longhorn_bucket" "$velero_bucket" "$management_bucket" "$pbs_bucket"; do
  ensure_bucket "$bucket"
  test_bucket "$bucket"
done

mkdir -p "$(dirname "$profile_file")"
if [[ "$mode" == "external-s3" ]]; then
  jq -n \
    --arg mode "$mode" --arg endpoint "$endpoint" --arg region "$region" \
    --argjson path_style "$path_style" \
    --arg access_key_id "$BACKUP_S3_ACCESS_KEY_ID" --arg secret_access_key "$BACKUP_S3_SECRET_ACCESS_KEY" \
    --arg databases "$database_bucket" --arg longhorn "$longhorn_bucket" \
    --arg velero "$velero_bucket" --arg management "$management_bucket" \
    --arg pbs "$pbs_bucket" \
    '{mode:$mode,endpoint:$endpoint,region:$region,path_style:$path_style,access_key_id:$access_key_id,secret_access_key:$secret_access_key,buckets:{databases:$databases,longhorn:$longhorn,velero:$velero,management:$management,pbs:$pbs}}' \
    >"$profile_file"
fi
chmod 0600 "$profile_file"
TWINBOX_CLUSTER_ID="$cluster_id" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/register-backup-vm-monitoring.sh"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  seaweedfs_backup_admin_url=""
  [[ "$mode" == "managed-seaweedfs" ]] && seaweedfs_backup_admin_url="$(jq -r '.admin.url // empty' "$profile_file")"
  jq -n \
    --arg mode "$mode" --arg endpoint "$endpoint" --arg region "$region" \
    --arg databases "$database_bucket" --arg longhorn "$longhorn_bucket" \
    --arg velero "$velero_bucket" --arg management "$management_bucket" --arg pbs "$pbs_bucket" \
    --arg seaweedfs_backup_admin_url "$seaweedfs_backup_admin_url" \
    '{mode:$mode,endpoint:$endpoint,region:$region,seaweedfs_backup_admin_url:$seaweedfs_backup_admin_url,secret_ref:{scope:"cluster",item:"backup-storage"},buckets:{databases:$databases,longhorn:$longhorn,velero:$velero,management:$management,pbs:$pbs}}' \
    >"$STEP_RESULT_FILE"
fi

log "External backup storage validated for cluster ${cluster_slug}"
