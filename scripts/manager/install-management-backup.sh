#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
HOST_CRON_DIR="${TWINBOX_HOST_CRON_DIR:-/host/etc/cron.d}"
HOST_REPO_ROOT="${TWINBOX_HOST_REPO_ROOT:-/opt/twinbox}"
VELERO_SECRET_FILE="${BOOTSTRAP_ROOT}/secrets/global/velero.json"
MANAGEMENT_BACKUP_FILE="${BOOTSTRAP_ROOT}/secrets/global/management-backup.json"
RUNTIME_SCRIPT="${BOOTSTRAP_ROOT}/bin/twinbox-management-backup.sh"
CRON_FILE="${HOST_CRON_DIR}/twinbox-management-backup"
RETENTION_DAYS="${TWINBOX_MANAGEMENT_BACKUP_RETENTION_DAYS:-30}"

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

cluster_json="$(printf '%s' "${STEP_CONTEXT_JSON:-{}}" | jq -c '.cluster // {}')"
cluster_id="${TWINBOX_CLUSTER_ID:-$(jq -r '.id // empty' <<<"$cluster_json")}"
controlplane_ip="$(jq -r '(.discovered_controlplane_ips[0] // .controlplane_ips[0] // empty)' <<<"$cluster_json")"
talosconfig_file="${TWINBOX_TALOSCONFIG_FILE:-}"

[[ -n "$cluster_id" ]] || fail "cluster id is required"
[[ -n "$controlplane_ip" ]] || fail "control-plane IP is required"
[[ -f "$VELERO_SECRET_FILE" ]] || fail "Velero/SeaweedFS bootstrap secret not found at ${VELERO_SECRET_FILE}"

if [[ -z "$talosconfig_file" ]]; then
  talosconfig_file="${BOOTSTRAP_ROOT}/secrets/cluster/${cluster_id}/talosconfig/talosconfig"
fi
[[ -f "$talosconfig_file" ]] || fail "talosconfig not found at ${talosconfig_file}"

endpoint="$(jq -r '.endpoint // empty' "$VELERO_SECRET_FILE")"
bucket="$(jq -r '.bucket // empty' "$VELERO_SECRET_FILE")"
region="$(jq -r '.region // "seaweedfs"' "$VELERO_SECRET_FILE")"
username="$(jq -r '.username // empty' "$VELERO_SECRET_FILE")"
password="$(jq -r '.password // empty' "$VELERO_SECRET_FILE")"

if [[ "$endpoint" == *".svc.cluster.local"* ]]; then
  management_ip="${MANAGEMENT_VM_IP:-}"
  [[ -n "$management_ip" ]] || fail "MANAGEMENT_VM_IP is required when Velero endpoint is cluster-internal"
  endpoint="http://${management_ip}:8333"
fi

[[ -n "$endpoint" ]] || fail "SeaweedFS endpoint is missing in ${VELERO_SECRET_FILE}"
[[ -n "$bucket" ]] || fail "SeaweedFS bucket is missing in ${VELERO_SECRET_FILE}"
[[ -n "$username" ]] || fail "SeaweedFS username is missing in ${VELERO_SECRET_FILE}"
[[ -n "$password" ]] || fail "SeaweedFS password is missing in ${VELERO_SECRET_FILE}"

mkdir -p "$(dirname "$MANAGEMENT_BACKUP_FILE")" "$(dirname "$RUNTIME_SCRIPT")"
restic_password=""
if [[ -f "$MANAGEMENT_BACKUP_FILE" ]]; then
  restic_password="$(jq -r '.restic_password // empty' "$MANAGEMENT_BACKUP_FILE" 2>/dev/null || printf '')"
fi
if [[ -z "$restic_password" ]]; then
  restic_password="$(openssl rand -hex 32)"
fi

jq -n \
  --arg mode "seaweedfs" \
  --arg endpoint "$endpoint" \
  --arg bucket "$bucket" \
  --arg region "$region" \
  --arg username "$username" \
  --arg password "$password" \
  --arg restic_password "$restic_password" \
  --arg cluster_id "$cluster_id" \
  --arg controlplane_ip "$controlplane_ip" \
  --arg talosconfig "$talosconfig_file" \
  --arg host_root "$HOST_REPO_ROOT" \
  --argjson retention_days "$RETENTION_DAYS" \
  '{
    mode: $mode,
    endpoint: $endpoint,
    bucket: $bucket,
    region: $region,
    username: $username,
    password: $password,
    restic_password: $restic_password,
    cluster_id: $cluster_id,
    controlplane_ip: $controlplane_ip,
    talosconfig: $talosconfig,
    host_root: $host_root,
    retention_days: $retention_days,
    exclude_paths: [
      ($host_root + "/seaweedfs/data")
    ]
  }' >"$MANAGEMENT_BACKUP_FILE"
chmod 0600 "$MANAGEMENT_BACKUP_FILE"

install -m 0755 /dev/stdin "$RUNTIME_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${TWINBOX_MANAGEMENT_BACKUP_CONFIG:-/opt/twinbox/bootstrap/secrets/global/management-backup.json}"
LOG_PREFIX="[twinbox-management-backup]"

log() { echo "${LOG_PREFIX} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
fail() { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

setting() {
  jq -r --arg key "$1" '.[$key] // empty' "$CONFIG_FILE"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

restic_repo() {
  local kind="$1"
  local endpoint bucket
  endpoint="$(setting endpoint)"
  bucket="$(setting bucket)"
  endpoint="${endpoint%/}"
  printf 's3:%s/%s/management-vm/%s' "$endpoint" "$bucket" "$kind"
}

restic_run() {
  local repo="$1"
  shift
  AWS_ACCESS_KEY_ID="$(setting username)" \
  AWS_SECRET_ACCESS_KEY="$(setting password)" \
  AWS_DEFAULT_REGION="$(setting region)" \
  AWS_REGION="$(setting region)" \
  RESTIC_PASSWORD="$(setting restic_password)" \
  RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/twinbox-restic}" \
    restic -r "$repo" "$@"
}

ensure_repo() {
  local repo="$1"
  mkdir -p "${RESTIC_CACHE_DIR:-/var/cache/twinbox-restic}"
  if ! restic_run "$repo" snapshots >/dev/null 2>&1; then
    log "Initializing restic repository ${repo}"
    restic_run "$repo" init >/dev/null
  fi
}

forget_old() {
  local repo="$1"
  local retention_days
  retention_days="$(setting retention_days)"
  [[ -n "$retention_days" ]] || retention_days="30"
  restic_run "$repo" forget "--keep-daily=${retention_days}" --prune >/dev/null
}

backup_etcd() {
  require_cmd talosctl
  local cluster_id controlplane_ip talosconfig snapshot_dir snapshot_path repo
  cluster_id="$(setting cluster_id)"
  controlplane_ip="$(setting controlplane_ip)"
  talosconfig="$(setting talosconfig)"
  [[ -n "$cluster_id" ]] || fail "cluster_id missing from ${CONFIG_FILE}"
  [[ -n "$controlplane_ip" ]] || fail "controlplane_ip missing from ${CONFIG_FILE}"
  [[ -f "$talosconfig" ]] || fail "talosconfig not found at ${talosconfig}"

  snapshot_dir="/opt/twinbox/bootstrap/backups/talos-etcd/${cluster_id}"
  snapshot_path="${snapshot_dir}/etcd-$(date -u '+%Y%m%dT%H%M%SZ').snapshot"
  mkdir -p "$snapshot_dir"

  log "Creating Talos etcd snapshot for cluster ${cluster_id}"
  talosctl etcd snapshot "$snapshot_path" \
    --nodes "$controlplane_ip" \
    --endpoints "$controlplane_ip" \
    --talosconfig "$talosconfig" >/dev/null

  repo="$(restic_repo etcd)"
  ensure_repo "$repo"
  log "Backing up Talos etcd snapshots"
  restic_run "$repo" backup "$snapshot_dir" >/dev/null
  forget_old "$repo"
  find "$snapshot_dir" -type f -name '*.snapshot' -mtime +7 -delete
}

backup_opt_twinbox() {
  local host_root repo
  host_root="$(setting host_root)"
  [[ -n "$host_root" ]] || host_root="/opt/twinbox"
  [[ -d "$host_root" ]] || fail "host root not found at ${host_root}"

  repo="$(restic_repo opt-twinbox)"
  ensure_repo "$repo"
  log "Backing up ${host_root}"
  restic_run "$repo" backup "$host_root" \
    --exclude "${host_root}/seaweedfs/data" >/dev/null
  forget_old "$repo"
}

main() {
  umask 077
  require_cmd jq
  require_cmd flock
  require_cmd restic
  [[ -f "$CONFIG_FILE" ]] || fail "config not found at ${CONFIG_FILE}"

  local lock_file="/opt/twinbox/bootstrap/management-backup.lock"
  mkdir -p "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  if ! flock -n 9; then
    log "Another backup run is active; exiting"
    exit 0
  fi

  case "${1:-}" in
    etcd)
      backup_etcd
      ;;
    opt-twinbox)
      backup_opt_twinbox
      ;;
    *)
      fail "usage: $0 {etcd|opt-twinbox}"
      ;;
  esac
}

main "$@"
SCRIPT

install -m 0644 /dev/stdin "$CRON_FILE" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

17 2 * * * root ${RUNTIME_SCRIPT} etcd >> ${HOST_REPO_ROOT}/manager-data/logs/management-backup.log 2>&1
47 2 * * * root ${RUNTIME_SCRIPT} opt-twinbox >> ${HOST_REPO_ROOT}/manager-data/logs/management-backup.log 2>&1
EOF

log "Installed Management VM backup cron at ${CRON_FILE}"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cron_file "$CRON_FILE" \
    --arg runtime_script "$RUNTIME_SCRIPT" \
    --arg config_file "$MANAGEMENT_BACKUP_FILE" \
    --arg retention_days "$RETENTION_DAYS" \
    '{
      cluster_id: $cluster_id,
      cron_file: $cron_file,
      runtime_script: $runtime_script,
      config_file: $config_file,
      retention_days: ($retention_days | tonumber)
    }' >"$STEP_RESULT_FILE"
fi
