#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
for command in aws curl jq openssl python3 scp ssh ssh-keygen tofu; do command -v "$command" >/dev/null 2>&1 || fail "$command not found"; done
: "${TWINBOX_CLUSTER_ID:?missing TWINBOX_CLUSTER_ID}"
: "${PROXMOX_HOST:?missing PROXMOX_HOST}"
: "${PROXMOX_USER:?missing PROXMOX_USER}"
: "${PROXMOX_PASSWORD:?missing PROXMOX_PASSWORD}"
: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
backup_secret_dir="${BOOTSTRAP_ROOT}/secrets/cluster/${TWINBOX_CLUSTER_ID}/backup-storage"
backup_profile="${backup_secret_dir}/metadata.json"
pbs_secret_dir="${BOOTSTRAP_ROOT}/secrets/cluster/${TWINBOX_CLUSTER_ID}/pbs"
pbs_profile="${pbs_secret_dir}/metadata.json"
state_file="${pbs_secret_dir}/pbs-vm.tfstate"
mkdir -p "$pbs_secret_dir"; chmod 0700 "$pbs_secret_dir"
[[ -s "$backup_profile" ]] || fail "Cluster backup storage profile is missing"

cluster_json="$(jq -c '.cluster' <<<"$STEP_CONTEXT_JSON")"
cluster_slug="$(jq -r '.slug // .id' <<<"$cluster_json" | tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g;s/^-+|-+$//g')"
datastore="$(jq -r '.pbs_datastore // empty' <<<"$STEP_INPUTS_JSON")"
cache_disk_gb="$(jq -r '.pbs_cache_disk_gb // 128' <<<"$STEP_INPUTS_JSON")"
ip_address="$(jq -r '.pbs_ip // empty' <<<"$STEP_INPUTS_JSON")"
bridge="$(jq -r '.bridge // empty' <<<"$cluster_json")"
prefix_length="$(jq -r '.node_prefix_length // empty' <<<"$cluster_json")"
gateway="$(jq -r '.gateway_ip // empty' <<<"$cluster_json")"
dns_csv="$(jq -r 'if (.dns_servers|type)=="array" then .dns_servers|join(",") else .dns_servers // empty end' <<<"$cluster_json")"
file_datastore="$(jq -r '.file_datastore // .metadata.file_datastore // empty' <<<"$cluster_json")"
[[ -n "$datastore" ]] || fail "PBS Proxmox datastore is required"
[[ "$cache_disk_gb" =~ ^[0-9]+$ && "$cache_disk_gb" -ge 64 ]] || fail "PBS cache disk must be at least 64 GiB"
[[ -n "$ip_address" && -n "$bridge" && -n "$prefix_length" && -n "$gateway" && -n "$dns_csv" && -n "$file_datastore" ]] || fail "PBS network or datastore settings are incomplete"
existing_datastore="$(jq -r '.datastore // empty' "$pbs_profile" 2>/dev/null || true)"
existing_cache_disk_gb="$(jq -r '.cache_disk_gb // empty' "$pbs_profile" 2>/dev/null || true)"
existing_ip_address="$(jq -r '.ip_address // empty' "$pbs_profile" 2>/dev/null || true)"
[[ -z "$existing_datastore" || "$datastore" == "$existing_datastore" ]] || fail "Refusing to move the existing PBS VM datastore"
[[ -z "$existing_cache_disk_gb" || "$cache_disk_gb" == "$existing_cache_disk_gb" ]] || fail "Refusing to resize the existing PBS cache disk implicitly"
[[ -z "$existing_ip_address" || "$ip_address" == "$existing_ip_address" ]] || fail "Refusing to change the existing PBS VM IP implicitly"
python3 - "$ip_address" "$gateway" "$prefix_length" <<'PY' || fail "PBS IP is outside the runtime-discovered cluster subnet"
import ipaddress, sys
ip, gateway, prefix = sys.argv[1:]
network = ipaddress.ip_network(f"{gateway}/{prefix}", strict=False)
assert ipaddress.ip_address(ip) in network
PY

endpoint="$(jq -r '.endpoint' "$backup_profile")"; region="$(jq -r '.region' "$backup_profile")"
access_key="$(jq -r '.access_key_id' "$backup_profile")"; secret_key="$(jq -r '.secret_access_key' "$backup_profile")"
bucket="$(jq -r '.buckets.pbs' "$backup_profile")"; path_style="$(jq -r '.path_style // true' "$backup_profile")"
ca_file="$(jq -r '.tls.ca_file // empty' "$backup_profile")"; s3_fingerprint="$(jq -r '.tls.fingerprint // empty' "$backup_profile")"
[[ "$endpoint" == https://* && -n "$access_key" && -n "$secret_key" && -n "$bucket" ]] || fail "PBS requires a complete HTTPS backup profile"
export AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" AWS_DEFAULT_REGION="$region"
[[ -z "$ca_file" ]] || export AWS_CA_BUNDLE="$ca_file"
aws_args=(--endpoint-url "$endpoint" s3api)
if ! aws "${aws_args[@]}" head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  aws "${aws_args[@]}" create-bucket --bucket "$bucket" >/dev/null 2>&1 || \
    aws "${aws_args[@]}" create-bucket --bucket "$bucket" --create-bucket-configuration "LocationConstraint=${region}" >/dev/null
fi
probe=".twinbox-pbs-sanity-${TWINBOX_CLUSTER_ID}"
printf 'pbs-sanity' | aws --endpoint-url "$endpoint" s3 cp - "s3://${bucket}/${probe}" >/dev/null
[[ "$(aws --endpoint-url "$endpoint" s3 cp "s3://${bucket}/${probe}" -)" == pbs-sanity ]] || fail "PBS bucket read test failed"
aws --endpoint-url "$endpoint" s3 rm "s3://${bucket}/${probe}" >/dev/null

api="https://${PROXMOX_HOST}:${PROXMOX_PORT:-8006}/api2/json"
auth="$(curl -ksS --data-urlencode "username=${PROXMOX_USER}" --data-urlencode "password=${PROXMOX_PASSWORD}" "${api}/access/ticket")"
ticket="$(jq -r '.data.ticket // empty' <<<"$auth")"; csrf="$(jq -r '.data.CSRFPreventionToken // empty' <<<"$auth")"
[[ -n "$ticket" && -n "$csrf" ]] || fail "Proxmox authentication failed"
pve_get() { curl -ksS -H "Cookie: PVEAuthCookie=${ticket}" "${api}$1"; }
pve_post() { local path="$1"; shift; curl -ksS -X POST -H "Cookie: PVEAuthCookie=${ticket}" -H "CSRFPreventionToken: ${csrf}" "$@" "${api}${path}"; }
pve_put() { local path="$1"; shift; curl -ksS -X PUT -H "Cookie: PVEAuthCookie=${ticket}" -H "CSRFPreventionToken: ${csrf}" "$@" "${api}${path}"; }
node_name="$(jq -r '.node // empty' "$pbs_profile" 2>/dev/null || true)"
[[ -n "$node_name" ]] || node_name="$(pve_get '/cluster/resources?type=node' | jq -r '.data|map(select(.status=="online"))|sort_by(-((.maxmem//0)-(.mem//0)))|.[0].node//empty')"
vm_id="$(jq -r '.vm_id // empty' "$pbs_profile" 2>/dev/null || true)"
[[ -n "$vm_id" ]] || vm_id="$(pve_get '/cluster/nextid' | jq -r '.data//empty')"
[[ "$vm_id" =~ ^[0-9]+$ && -n "$node_name" ]] || fail "Could not select a PBS VMID and node"
address_in_use() {
  ping -c 1 -W 1 "$ip_address" >/dev/null 2>&1 || \
    curl -ksS --connect-timeout 1 "https://${ip_address}/" >/dev/null 2>&1 || \
    curl -sS --connect-timeout 1 "http://${ip_address}/" >/dev/null 2>&1 || \
    { command -v ip >/dev/null 2>&1 && ip neigh show "$ip_address" 2>/dev/null | grep -Eq 'REACHABLE|STALE|DELAY|PROBE'; }
}
if [[ ! -s "$pbs_profile" ]] && address_in_use; then fail "PBS IP ${ip_address} is already in use"; fi

ssh_private_key="${pbs_secret_dir}/vm-ssh-key"
[[ -f "$ssh_private_key" ]] || ssh-keygen -q -t ed25519 -N '' -C "twinbox-${cluster_slug}-pbs" -f "$ssh_private_key"
pbs_admin_password="$(jq -r '.admin_password // empty' "$pbs_profile" 2>/dev/null || true)"
[[ -n "$pbs_admin_password" ]] || pbs_admin_password="$(openssl rand -base64 32 | tr -d '\n')"
existing_token_value="$(jq -r '.token_value // empty' "$pbs_profile" 2>/dev/null || true)"
jq -n --argjson vm_id "$vm_id" --arg node "$node_name" --arg datastore "$datastore" --argjson cache_disk_gb "$cache_disk_gb" --arg ip "$ip_address" --arg ssh_private_key "$ssh_private_key" --arg admin_password "$pbs_admin_password" --arg token_value "$existing_token_value" \
  '{vm_id:$vm_id,node:$node,datastore:$datastore,cache_disk_gb:$cache_disk_gb,ip_address:$ip,ssh_private_key:$ssh_private_key,admin_password:$admin_password,token_value:$token_value,status:"provisioning"}' >"$pbs_profile"
chmod 0600 "$pbs_profile" "$ssh_private_key"
cloud_init="$(mktemp "${TMPDIR:-/tmp}/twinbox-pbs-cloud-init-XXXXXX")"; trap 'rm -f "$cloud_init"' EXIT
ssh_authorized_key="$(<"${ssh_private_key}.pub")"
cat >"$cloud_init" <<EOF
#cloud-config
package_update: true
packages: [qemu-guest-agent, curl, ca-certificates, gnupg]
users:
  - name: twinbox
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_authorized_key}
runcmd:
  - systemctl enable --now qemu-guest-agent
  - echo 'deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription' > /etc/apt/sources.list.d/pbs.list
  - curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg -o /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-backup-server
  - touch /run/twinbox-pbs-installed
EOF
dns_json="$(jq -cn --arg csv "$dns_csv" '$csv|split(",")|map(gsub("^\\s+|\\s+$";""))')"
export TF_VAR_proxmox_endpoint="https://${PROXMOX_HOST}:${PROXMOX_PORT:-8006}" TF_VAR_proxmox_username="$PROXMOX_USER" TF_VAR_proxmox_password="$PROXMOX_PASSWORD"
export TF_VAR_node_name="$node_name" TF_VAR_vm_id="$vm_id" TF_VAR_vm_name="${cluster_slug}-pbs" TF_VAR_datastore_id="$datastore" TF_VAR_file_datastore_id="$file_datastore"
export TF_VAR_bridge="$bridge" TF_VAR_ip_address="$ip_address" TF_VAR_prefix_length="$prefix_length" TF_VAR_gateway="$gateway" TF_VAR_dns_servers="$dns_json"
export TF_VAR_cache_disk_gb="$cache_disk_gb" TF_VAR_cloud_init="$(<"$cloud_init")"
module="$WORKSPACE_ROOT/infra/opentofu/pbs-backup"; tofu -chdir="$module" init -input=false >/dev/null; tofu -chdir="$module" apply -input=false -auto-approve -state="$state_file" >/dev/null

ssh_opts=(-i "$ssh_private_key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
for attempt in $(seq 1 90); do
  ssh "${ssh_opts[@]}" "twinbox@${ip_address}" 'test -f /run/twinbox-pbs-installed' >/dev/null 2>&1 && break
  [[ "$attempt" -lt 90 ]] || fail "PBS installation did not become ready"
  log "Waiting for PBS package installation (attempt ${attempt}/90)"
  sleep 10
done
password_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-pbs-password-XXXXXX")"
trap 'rm -f "$cloud_init" "$password_file"' EXIT
printf 'root:%s\n' "$pbs_admin_password" >"$password_file"; chmod 0600 "$password_file"
scp "${ssh_opts[@]}" "$password_file" "twinbox@${ip_address}:/tmp/twinbox-pbs-password" >/dev/null
ssh "${ssh_opts[@]}" "twinbox@${ip_address}" 'sudo chpasswd </tmp/twinbox-pbs-password; rm -f /tmp/twinbox-pbs-password'
remote="ssh ${ssh_opts[*]} twinbox@${ip_address}"
endpoint_no_scheme="${endpoint#https://}"; endpoint_hostport="${endpoint_no_scheme%%/*}"; endpoint_host="${endpoint_hostport%%:*}"; endpoint_port="${endpoint_hostport##*:}"
[[ "$endpoint_port" != "$endpoint_hostport" ]] || endpoint_port=443
s3_create=(sudo proxmox-backup-manager s3 endpoint create twinbox-s3 --access-key "$access_key" --secret-key "$secret_key" --endpoint "$endpoint_host" --port "$endpoint_port" --region "$region")
[[ "$path_style" == true ]] && s3_create+=(--path-style true)
[[ -n "$s3_fingerprint" ]] && s3_create+=(--fingerprint "$s3_fingerprint")
$remote 'sudo test -b /dev/sdb && (sudo blkid /dev/sdb || sudo mkfs.ext4 -F /dev/sdb); sudo mkdir -p /mnt/datastore/twinbox-s3-cache; grep -q twinbox-s3-cache /etc/fstab || echo "/dev/sdb /mnt/datastore/twinbox-s3-cache ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null; sudo mount -a'
if $remote 'sudo proxmox-backup-manager s3 endpoint show twinbox-s3 >/dev/null 2>&1'; then
  s3_update=(sudo proxmox-backup-manager s3 endpoint update twinbox-s3 --access-key "$access_key" --secret-key "$secret_key" --endpoint "$endpoint_host" --port "$endpoint_port" --region "$region")
  [[ "$path_style" == true ]] && s3_update+=(--path-style true)
  [[ -n "$s3_fingerprint" ]] && s3_update+=(--fingerprint "$s3_fingerprint")
  ssh "${ssh_opts[@]}" "twinbox@${ip_address}" "${s3_update[@]}"
else
  ssh "${ssh_opts[@]}" "twinbox@${ip_address}" "${s3_create[@]}"
fi
if $remote 'sudo proxmox-backup-manager datastore show twinbox-s3 >/dev/null 2>&1'; then
  ssh "${ssh_opts[@]}" "twinbox@${ip_address}" sudo proxmox-backup-manager datastore update twinbox-s3 --backend "type=s3,client=twinbox-s3,bucket=${bucket}"
else
  ssh "${ssh_opts[@]}" "twinbox@${ip_address}" sudo proxmox-backup-manager datastore create twinbox-s3 /mnt/datastore/twinbox-s3-cache --backend "type=s3,client=twinbox-s3,bucket=${bucket}"
fi
$remote 'sudo proxmox-backup-manager user list --output-format json | jq -e '\''map(select(.userid=="pve@pbs"))|length==1'\'' >/dev/null' || $remote 'sudo proxmox-backup-manager user create pve@pbs'
token_value="$existing_token_value"
if [[ -z "$token_value" ]]; then
  token_json="$($remote 'sudo proxmox-backup-manager user generate-token pve@pbs twinbox --output-format json' 2>/dev/null || true)"
  token_value="$(jq -r '.value // empty' <<<"$token_json")"
  if [[ -z "$token_value" ]]; then
    $remote 'sudo proxmox-backup-manager user delete-token pve@pbs twinbox >/dev/null 2>&1 || true'
    token_json="$($remote 'sudo proxmox-backup-manager user generate-token pve@pbs twinbox --output-format json')"
    token_value="$(jq -r '.value // empty' <<<"$token_json")"
  fi
fi
[[ -n "$token_value" ]] || fail "Could not create or recover PBS API token"
jq --arg token_value "$token_value" '.token_value=$token_value | .status="configuring"' "$pbs_profile" >"${pbs_profile}.tmp"
mv "${pbs_profile}.tmp" "$pbs_profile"; chmod 0600 "$pbs_profile"
$remote 'sudo proxmox-backup-manager acl update /datastore/twinbox-s3 DatastoreBackup --auth-id pve@pbs!twinbox'
pbs_fingerprint="$($remote "sudo proxmox-backup-manager cert info | sed -n 's/^Fingerprint (sha256): //p'" | head -1)"
[[ -n "$pbs_fingerprint" ]] || fail "Could not read PBS certificate fingerprint"

storage_id="twinbox-pbs-${cluster_slug}"; storage_list="$(pve_get '/storage')"
if ! jq -e --arg id "$storage_id" '.data|any(.storage==$id)' <<<"$storage_list" >/dev/null; then
  pve_post '/storage' --data-urlencode "storage=${storage_id}" --data-urlencode 'type=pbs' --data-urlencode "server=${ip_address}" --data-urlencode 'datastore=twinbox-s3' --data-urlencode 'username=pve@pbs!twinbox' --data-urlencode "password=${token_value}" --data-urlencode "fingerprint=${pbs_fingerprint}" --data-urlencode 'content=backup' >/dev/null
else
  pve_put "/storage/${storage_id}" --data-urlencode "server=${ip_address}" --data-urlencode 'datastore=twinbox-s3' --data-urlencode 'username=pve@pbs!twinbox' --data-urlencode "password=${token_value}" --data-urlencode "fingerprint=${pbs_fingerprint}" --data-urlencode 'content=backup' >/dev/null
fi
resources="$(pve_get '/cluster/resources?type=vm')"
exclude_vmids="${vm_id}"
seaweed_vmid="$(jq -r '.vm.vm_id // empty' "$backup_profile")"; [[ -z "$seaweed_vmid" ]] || exclude_vmids+=",${seaweed_vmid}"
talos_vmids="$(jq -r '[.nodes[]?.vm_id]|map(select(. != null))|join(",")' <<<"$cluster_json")"
management_vmid="${MANAGEMENT_VM_ID:-}"
[[ "$management_vmid" =~ ^[0-9]+$ ]] || fail "MANAGEMENT_VM_ID is required for the PBS backup job"
include_vmids="$(printf '%s,%s' "$management_vmid" "$talos_vmids" | sed -E 's/,+/,/g;s/^,|,$//g')"
for excluded in ${exclude_vmids//,/ }; do include_vmids="$(printf '%s' "$include_vmids" | tr ',' '\n' | awk -v id="$excluded" '$0 != id' | paste -sd, -)"; done
[[ -n "$include_vmids" ]] || fail "No Management or Talos VMs found for the PBS backup job"
job_id="twinbox-${cluster_slug}-daily"
jobs="$(pve_get '/cluster/backup')"
if ! jq -e --arg id "$job_id" '.data|any(.id==$id)' <<<"$jobs" >/dev/null; then
  pve_post '/cluster/backup' --data-urlencode "id=${job_id}" --data-urlencode "storage=${storage_id}" --data-urlencode "vmid=${include_vmids}" --data-urlencode 'schedule=02:30' --data-urlencode 'mode=snapshot' --data-urlencode 'enabled=1' --data-urlencode 'prune-backups=keep-daily=14,keep-weekly=8,keep-monthly=12' >/dev/null
fi
first_vmid="${include_vmids%%,*}"; first_node="$(jq -r --argjson id "$first_vmid" '.data[]|select(.vmid==$id)|.node' <<<"$resources")"
backup_result="$(pve_post "/nodes/${first_node}/vzdump" --data-urlencode "vmid=${first_vmid}" --data-urlencode "storage=${storage_id}" --data-urlencode 'mode=snapshot')"
upid="$(jq -r '.data//empty' <<<"$backup_result")"; [[ -n "$upid" ]] || fail "Could not start PBS verification backup"
encoded_upid="$(jq -rn --arg v "$upid" '$v|@uri')"
for attempt in $(seq 1 180); do status="$(pve_get "/nodes/${first_node}/tasks/${encoded_upid}/status")"; state="$(jq -r '.data.status//empty' <<<"$status")"; [[ "$state" != stopped ]] || { [[ "$(jq -r '.data.exitstatus' <<<"$status")" == OK ]] || fail "PBS verification backup failed"; break; }; [[ "$attempt" -lt 180 ]] || fail "PBS verification backup timed out"; sleep 10; done
snapshot_json="$(ssh "${ssh_opts[@]}" "twinbox@${ip_address}" "PBS_PASSWORD='${token_value}' sudo -E proxmox-backup-client snapshot list --repository 'pve@pbs!twinbox@localhost:twinbox-s3' --output-format json")"
latest_snapshot="$(jq -r --arg vmid "$first_vmid" '[.[]|select(.["backup-type"]=="vm" and (.["backup-id"]|tostring)==$vmid)]|sort_by(.["backup-time"])|last|"vm/\(.["backup-id"])/\(.["backup-time"]|strftime("%Y-%m-%dT%H:%M:%SZ"))"' <<<"$snapshot_json")"
[[ -n "$latest_snapshot" && "$latest_snapshot" != null ]] || fail "PBS restore-read-test could not find the verification snapshot"
ssh "${ssh_opts[@]}" "twinbox@${ip_address}" "tmp=\$(mktemp); trap 'rm -f \"\$tmp\"' EXIT; PBS_PASSWORD='${token_value}' sudo -E proxmox-backup-client restore '${latest_snapshot}' qemu-server.conf.blob \"\$tmp\" --repository 'pve@pbs!twinbox@localhost:twinbox-s3' >/dev/null; test -s \"\$tmp\"" || fail "PBS restore-read-test failed"

jq -n --argjson vm_id "$vm_id" --arg node "$node_name" --arg datastore "$datastore" --argjson cache_disk_gb "$cache_disk_gb" --arg ip "$ip_address" --arg ssh_private_key "$ssh_private_key" --arg fingerprint "$pbs_fingerprint" --arg token_value "$token_value" --arg admin_password "$pbs_admin_password" --arg storage_id "$storage_id" --arg exclude_vmids "$exclude_vmids" \
  '{vm_id:$vm_id,node:$node,datastore:$datastore,cache_disk_gb:$cache_disk_gb,ip_address:$ip,ssh_private_key:$ssh_private_key,fingerprint:$fingerprint,token_value:$token_value,admin_password:$admin_password,pve_storage_id:$storage_id,exclude_vmids:$exclude_vmids,status:"ready",verification:"backup-and-restore-read-test"}' >"$pbs_profile"
chmod 0600 "$pbs_profile" "$ssh_private_key"
if [[ -n "${NETBIRD_SETUP_KEY:-}" && -n "${NETBIRD_MANAGEMENT_URL:-}" ]]; then
  NETBIRD_SETUP_KEY="$NETBIRD_SETUP_KEY" NETBIRD_MANAGEMENT_URL="$NETBIRD_MANAGEMENT_URL" \
    bash "$WORKSPACE_ROOT/scripts/manager/register-backup-vms-netbird.sh"
fi
jq -n --argjson vm_id "$vm_id" --arg node "$node_name" --arg storage_id "$storage_id" '{pbs_vm_id:$vm_id,node:$node,storage_id:$storage_id,verification:"backup-and-restore-read-test"}' >"${STEP_RESULT_FILE:?missing STEP_RESULT_FILE}"
log "PBS VM ${vm_id}, S3 datastore, backup job, backup, and restore-read-test completed"
