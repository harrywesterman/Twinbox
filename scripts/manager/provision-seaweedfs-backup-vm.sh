#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

for command in curl jq node openssl python3 scp ssh ssh-keygen tofu xorriso; do command -v "$command" >/dev/null 2>&1 || fail "$command not found"; done
: "${TWINBOX_CLUSTER_ID:?missing TWINBOX_CLUSTER_ID}"
: "${PROXMOX_HOST:?missing PROXMOX_HOST}"
: "${PROXMOX_USER:?missing PROXMOX_USER}"
: "${PROXMOX_PASSWORD:?missing PROXMOX_PASSWORD}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/backup-bucket-name.sh"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
secret_dir="${BOOTSTRAP_ROOT}/secrets/cluster/${TWINBOX_CLUSTER_ID}/backup-storage"
profile_file="${secret_dir}/metadata.json"
state_file="${secret_dir}/seaweedfs-vm.tfstate"
mkdir -p "$secret_dir"
chmod 0700 "$secret_dir"

cluster_json="$(jq -c '.cluster' <<<"$STEP_CONTEXT_JSON")"
cluster_slug="$(jq -r '.slug // .id' <<<"$cluster_json")"
datastore="$(jq -r '.seaweedfs_datastore // empty' <<<"$STEP_INPUTS_JSON")"
data_disk_gb="$(jq -r '.seaweedfs_data_disk_gb // 500' <<<"$STEP_INPUTS_JSON")"
ip_address="$(jq -r '.seaweedfs_ip // empty' <<<"$STEP_INPUTS_JSON")"
requested_node="$(jq -r '.seaweedfs_node // empty' <<<"$STEP_INPUTS_JSON")"
bridge="$(jq -r '.bridge // "vmbr0"' <<<"$cluster_json")"
prefix_length="$(jq -r '.node_prefix_length // empty' <<<"$cluster_json")"
gateway="$(jq -r '.gateway_ip // empty' <<<"$cluster_json")"
dns_csv="$(jq -r 'if (.dns_servers|type)=="array" then .dns_servers|join(",") else .dns_servers // empty end' <<<"$cluster_json")"
file_datastore="$(jq -r '.file_datastore // .metadata.file_datastore // empty' <<<"$cluster_json")"

[[ -n "$datastore" ]] || fail "SeaweedFS Proxmox datastore is required"
[[ "$data_disk_gb" =~ ^[0-9]+$ && "$data_disk_gb" -ge 100 ]] || fail "SeaweedFS data disk must be at least 100 GiB"
[[ -n "$ip_address" && -n "$prefix_length" && -n "$gateway" && -n "$dns_csv" ]] || fail "SeaweedFS network settings are incomplete"
python3 - "$ip_address" "$gateway" "$prefix_length" <<'PY' || fail "SeaweedFS IP is outside the runtime-discovered cluster subnet"
import ipaddress, sys
ip, gateway, prefix = sys.argv[1:]
network = ipaddress.ip_network(f"{gateway}/{prefix}", strict=False)
assert ipaddress.ip_address(ip) in network
PY
address_in_use() {
  ping -c 1 -W 1 "$ip_address" >/dev/null 2>&1 || \
    curl -ksS --connect-timeout 1 "https://${ip_address}/" >/dev/null 2>&1 || \
    curl -sS --connect-timeout 1 "http://${ip_address}/" >/dev/null 2>&1 || \
    { command -v ip >/dev/null 2>&1 && ip neigh show "$ip_address" 2>/dev/null | grep -Eq 'REACHABLE|STALE|DELAY|PROBE'; }
}
existing_vm_id="$(jq -r '.vm.vm_id // empty' "$profile_file" 2>/dev/null || true)"
existing_datastore="$(jq -r '.vm.datastore // empty' "$profile_file" 2>/dev/null || true)"
existing_data_disk_gb="$(jq -r '.vm.data_disk_gb // empty' "$profile_file" 2>/dev/null || true)"
existing_ip_address="$(jq -r '.vm.ip_address // empty' "$profile_file" 2>/dev/null || true)"
[[ -z "$existing_datastore" || "$datastore" == "$existing_datastore" ]] || fail "Refusing to move the existing SeaweedFS VM datastore"
[[ -z "$existing_data_disk_gb" || "$data_disk_gb" == "$existing_data_disk_gb" ]] || fail "Refusing to resize the existing SeaweedFS data disk implicitly"
[[ -z "$existing_ip_address" || "$ip_address" == "$existing_ip_address" ]] || fail "Refusing to change the existing SeaweedFS VM IP implicitly"
if [[ -z "$existing_vm_id" ]] && address_in_use; then
  fail "SeaweedFS IP ${ip_address} is already in use"
fi

api="https://${PROXMOX_HOST}:${PROXMOX_PORT:-8006}/api2/json"
auth="$(curl -ksS --data-urlencode "username=${PROXMOX_USER}" --data-urlencode "password=${PROXMOX_PASSWORD}" "${api}/access/ticket")"
ticket="$(jq -r '.data.ticket // empty' <<<"$auth")"
csrf="$(jq -r '.data.CSRFPreventionToken // empty' <<<"$auth")"
[[ -n "$ticket" && -n "$csrf" ]] || fail "Proxmox authentication failed"
nodes="$(curl -ksS -H "Cookie: PVEAuthCookie=${ticket}" "${api}/cluster/resources?type=node")"
node_name="$(jq -r '.vm.node // empty' "$profile_file" 2>/dev/null || true)"
[[ -z "$node_name" || -z "$requested_node" || "$node_name" == "$requested_node" ]] || fail "Refusing to move the existing SeaweedFS VM host"
[[ -n "$node_name" ]] || node_name="$requested_node"
[[ -n "$node_name" ]] || fail "Select a SeaweedFS Proxmox host in backup storage first"
encoded_node="$(jq -rn --arg node "$node_name" '$node|@uri')"
# A saved allocation from a failed apply is not an existing VM.
vm_exists=false
if [[ -n "$existing_vm_id" ]]; then
  inventory="$(curl -fksS -H "Cookie: PVEAuthCookie=${ticket}" "${api}/cluster/resources?type=vm")"
  actual_vm="$(jq -c --arg id "$existing_vm_id" '.data[] | select((.vmid|tostring)==$id)' <<<"$inventory")"
  if [[ -n "$actual_vm" ]]; then
    [[ "$(jq -r '.node' <<<"$actual_vm")" == "$node_name" && "$(jq -r '.name' <<<"$actual_vm")" == "${cluster_slug}-backup-s3" ]] || fail "Saved SeaweedFS VMID belongs to a different VM or host"
    vm_exists=true
  fi
fi
storages="$(curl -fksS -H "Cookie: PVEAuthCookie=${ticket}" "${api}/nodes/${encoded_node}/storage")"
networks="$(curl -fksS -H "Cookie: PVEAuthCookie=${ticket}" "${api}/nodes/${encoded_node}/network")"
existing_vm="$(jq -c '.vm // null' "$profile_file" 2>/dev/null || echo null)"
[[ "$vm_exists" == true ]] || existing_vm=null
file_datastore="$(jq -n --argjson cluster "$cluster_json" --argjson inputs "$STEP_INPUTS_JSON" \
  --argjson nodes "$nodes" --argjson storages "$storages" --argjson networks "$networks" \
  --argjson existing "$existing_vm" --arg node "$node_name" \
  '{cluster:$cluster,inputs:($inputs + {seaweedfs_node:$node}),existing:$existing,nodes:$nodes.data,storages:[$storages.data[] + {node:$node}],networks:[$networks.data[] + {node:$node}]}' | \
  node "$WORKSPACE_ROOT/scripts/manager/check-seaweedfs-placement.mjs")" || fail "SeaweedFS placement validation failed"
vm_id="$(jq -r '.vm.vm_id // empty' "$profile_file" 2>/dev/null || true)"
[[ -n "$vm_id" ]] || vm_id="$(curl -ksS -H "Cookie: PVEAuthCookie=${ticket}" "${api}/cluster/nextid" | jq -r '.data // empty')"
[[ "$vm_id" =~ ^[0-9]+$ ]] || fail "Could not allocate a Proxmox VMID"

profile_mode="$(jq -r '.mode // empty' "$profile_file" 2>/dev/null || true)"
access_key_id=""; secret_access_key=""
if [[ "$profile_mode" == managed-seaweedfs ]]; then
  access_key_id="$(jq -r '.access_key_id // empty' "$profile_file")"
  secret_access_key="$(jq -r '.secret_access_key // empty' "$profile_file")"
fi
[[ -n "$access_key_id" ]] || access_key_id="twinbox-${cluster_slug}"
[[ -n "$secret_access_key" ]] || secret_access_key="$(openssl rand -hex 32)"

ca_key="${secret_dir}/ca.key"
ca_cert="${secret_dir}/ca.crt"
server_key="${secret_dir}/server.key"
server_cert="${secret_dir}/server.crt"
ssh_private_key="${secret_dir}/vm-ssh-key"
ssh_public_key="${ssh_private_key}.pub"
if [[ ! -f "$ssh_private_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C "twinbox-${cluster_slug}-backup-s3" -f "$ssh_private_key"
fi
if [[ ! -f "$ca_key" || ! -f "$ca_cert" ]]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=Twinbox Backup CA ${cluster_slug}" -keyout "$ca_key" -out "$ca_cert" >/dev/null 2>&1
fi
if [[ ! -f "$server_key" || ! -f "$server_cert" ]]; then
  openssl req -newkey rsa:2048 -nodes -subj "/CN=${ip_address}" -addext "subjectAltName=IP:${ip_address}" -keyout "$server_key" -out "${secret_dir}/server.csr" >/dev/null 2>&1
  openssl x509 -req -days 825 -in "${secret_dir}/server.csr" -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial -copy_extensions copy -out "$server_cert" >/dev/null 2>&1
fi
chmod 0600 "$ca_key" "$server_key" "$profile_file" 2>/dev/null || true
fingerprint="$(openssl x509 -in "$server_cert" -noout -fingerprint -sha256 | cut -d= -f2)"
database_bucket="$(twinbox_backup_bucket_name "$cluster_slug" databases)"
longhorn_bucket="$(twinbox_backup_bucket_name "$cluster_slug" longhorn)"
velero_bucket="$(twinbox_backup_bucket_name "$cluster_slug" velero)"
management_bucket="$(twinbox_backup_bucket_name "$cluster_slug" management)"
pbs_bucket="$(twinbox_backup_bucket_name "$cluster_slug" pbs)"
bucket_csv="${database_bucket},${longhorn_bucket},${velero_bucket},${management_bucket}"
write_provisioning_profile() {
jq -n --arg mode managed-seaweedfs --arg endpoint "https://${ip_address}" --arg region us-east-1 \
  --arg access_key_id "$access_key_id" --arg secret_access_key "$secret_access_key" --arg ca_file "$ca_cert" --arg fingerprint "$fingerprint" \
  --arg node "$node_name" --argjson vm_id "$vm_id" --arg datastore "$datastore" --argjson data_disk_gb "$data_disk_gb" \
  --arg databases "$database_bucket" --arg longhorn "$longhorn_bucket" --arg velero "$velero_bucket" --arg management "$management_bucket" --arg pbs "$pbs_bucket" \
  --arg ssh_private_key "$ssh_private_key" --arg ip_address "$ip_address" \
  '{mode:$mode,endpoint:$endpoint,region:$region,path_style:true,access_key_id:$access_key_id,secret_access_key:$secret_access_key,tls:{ca_file:$ca_file,fingerprint:$fingerprint},buckets:{databases:$databases,longhorn:$longhorn,velero:$velero,management:$management,pbs:$pbs},vm:{vm_id:$vm_id,node:$node,datastore:$datastore,data_disk_gb:$data_disk_gb,ip_address:$ip_address,ssh_private_key:$ssh_private_key,status:"provisioning"}}' >"$profile_file"
chmod 0600 "$profile_file"
}

seed_dir="$(mktemp -d "${TMPDIR:-/tmp}/twinbox-seaweedfs-seed-XXXXXX")"
cloud_init="${seed_dir}/user-data"
trap 'rm -rf "$seed_dir"' EXIT
ssh_authorized_key="$(<"$ssh_public_key")"
cat >"$cloud_init" <<EOF
#cloud-config
package_update: true
packages: [docker.io, nginx, qemu-guest-agent]
users:
  - name: twinbox
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_authorized_key}
write_files:
  - path: /etc/nginx/sites-available/default
    defer: true
    content: |
      server { listen 443 ssl; ssl_certificate /etc/nginx/twinbox-server.crt; ssl_certificate_key /etc/nginx/twinbox-server.key; location / { proxy_pass http://127.0.0.1:8333; proxy_set_header Host \$host; } }
runcmd:
  - systemctl enable --now qemu-guest-agent docker
  - 'test -b /dev/sdb && (blkid /dev/sdb || mkfs.ext4 -F /dev/sdb)'
  - mkdir -p /srv/seaweedfs
  - 'grep -q /srv/seaweedfs /etc/fstab || echo "/dev/sdb /srv/seaweedfs ext4 defaults,nofail 0 2" >> /etc/fstab'
  - mount -a
  - 'docker run -d --name seaweedfs --restart unless-stopped -p 127.0.0.1:8333:8333 -v /srv/seaweedfs:/data chrislusf/seaweedfs:4.44 server -dir=/data -s3'
  - touch /run/twinbox-seaweedfs-installed
EOF

dns_json="$(jq -cn --arg csv "$dns_csv" '$csv | split(",") | map(gsub("^\\s+|\\s+$";""))')"
jq -n --arg id "${cluster_slug}-backup-s3-${vm_id}" --arg hostname "${cluster_slug}-backup-s3" \
  '{"instance-id":$id,"local-hostname":$hostname}' >"${seed_dir}/meta-data"
jq -n --arg address "${ip_address}/${prefix_length}" --arg gateway "$gateway" --argjson dns "$dns_json" \
  '{version:2,ethernets:{primary:{match:{name:"en*"},dhcp4:false,addresses:[$address],routes:[{to:"default",via:$gateway}],nameservers:{addresses:$dns}}}}' >"${seed_dir}/network-config"
xorriso -as mkisofs -output "${secret_dir}/cidata.iso" -volid cidata -joliet -rock \
  "${seed_dir}/user-data" "${seed_dir}/meta-data" "${seed_dir}/network-config" >/dev/null 2>&1
export TF_VAR_proxmox_endpoint="https://${PROXMOX_HOST}:${PROXMOX_PORT:-8006}"
export TF_VAR_proxmox_username="$PROXMOX_USER" TF_VAR_proxmox_password="$PROXMOX_PASSWORD"
export TF_VAR_node_name="$node_name" TF_VAR_vm_id="$vm_id" TF_VAR_vm_name="${cluster_slug}-backup-s3"
export TF_VAR_datastore_id="$datastore" TF_VAR_file_datastore_id="$file_datastore" TF_VAR_bridge="$bridge"
export TF_VAR_data_disk_gb="$data_disk_gb" TF_VAR_cloud_init_iso_path="${secret_dir}/cidata.iso"
module="$WORKSPACE_ROOT/infra/opentofu/seaweedfs-backup"
tofu -chdir="$module" init -input=false >/dev/null
if [[ "$vm_exists" == false ]] && address_in_use; then
  fail "SeaweedFS IP ${ip_address} became occupied before VM creation; choose another address"
fi
write_provisioning_profile
if [[ "$vm_exists" == false ]]; then
  tofu -chdir="$module" apply -input=false -auto-approve -state="$state_file" >/dev/null
fi

ssh_opts=(-i "$ssh_private_key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
for attempt in $(seq 1 60); do
  ssh "${ssh_opts[@]}" "twinbox@${ip_address}" 'test -f /run/twinbox-seaweedfs-installed' >/dev/null 2>&1 && break
  [[ "$attempt" -lt 60 ]] || fail "SeaweedFS VM did not become ready"
  log "Waiting for the SeaweedFS VM (attempt ${attempt}/60)"
  sleep 5
done
remote_secret="$(mktemp "${TMPDIR:-/tmp}/twinbox-seaweedfs-iam-XXXXXX")"
policy_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-seaweedfs-policy-XXXXXX")"
trap 'rm -rf "$seed_dir"; rm -f "$remote_secret" "$policy_file"' EXIT
jq -n --argjson buckets "$(jq -cn --arg csv "$bucket_csv" '$csv|split(",")')" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["s3:CreateBucket","s3:ListBucket"],Resource:($buckets|map("arn:aws:s3:::" + .))},{Effect:"Allow",Action:["s3:GetObject","s3:PutObject","s3:DeleteObject"],Resource:($buckets|map("arn:aws:s3:::" + . + "/*"))}]}' >"$policy_file"
printf 's3.user.create -name %s -access_key %s -secret_key %s\ns3.policy -put -name=twinbox-backup -file=/tmp/policy.json\ns3.policy.attach -policy=twinbox-backup -user=%s\ns3.bucket.create -name=%s\ns3.bucket.create -name=%s\ns3.bucket.create -name=%s\ns3.bucket.create -name=%s\n' \
  "$access_key_id" "$access_key_id" "$secret_access_key" "$access_key_id" \
  "$database_bucket" "$longhorn_bucket" "$velero_bucket" "$management_bucket" >"$remote_secret"
chmod 0600 "$remote_secret"
scp "${ssh_opts[@]}" "$ca_cert" "$server_cert" "$server_key" "$remote_secret" "$policy_file" "twinbox@${ip_address}:/tmp/" >/dev/null
# These generated basenames intentionally expand locally; SSH targets only the guest VM.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "twinbox@${ip_address}" \
  "set -e; sudo install -m 0644 /tmp/$(basename "$ca_cert") /usr/local/share/ca-certificates/twinbox-backup-ca.crt; sudo install -m 0644 /tmp/$(basename "$server_cert") /etc/nginx/twinbox-server.crt; sudo install -m 0600 /tmp/$(basename "$server_key") /etc/nginx/twinbox-server.key; sudo update-ca-certificates; sudo docker cp /tmp/$(basename "$policy_file") seaweedfs:/tmp/policy.json; sudo docker exec -i seaweedfs weed shell </tmp/$(basename "$remote_secret"); sudo rm -f /tmp/$(basename "$ca_cert") /tmp/$(basename "$server_cert") /tmp/$(basename "$server_key") /tmp/$(basename "$remote_secret") /tmp/$(basename "$policy_file"); sudo nginx -t; sudo systemctl enable nginx; sudo systemctl restart nginx"

jq -n --arg mode managed-seaweedfs --arg endpoint "https://${ip_address}" --arg region us-east-1 \
  --arg access_key_id "$access_key_id" --arg secret_access_key "$secret_access_key" --arg ca_file "$ca_cert" --arg fingerprint "$fingerprint" \
  --arg node "$node_name" --argjson vm_id "$vm_id" --arg datastore "$datastore" --argjson data_disk_gb "$data_disk_gb" \
  --arg databases "$database_bucket" --arg longhorn "$longhorn_bucket" --arg velero "$velero_bucket" --arg management "$management_bucket" --arg pbs "$pbs_bucket" \
  --arg ssh_private_key "$ssh_private_key" --arg ip_address "$ip_address" \
  '{mode:$mode,endpoint:$endpoint,region:$region,path_style:true,access_key_id:$access_key_id,secret_access_key:$secret_access_key,tls:{ca_file:$ca_file,fingerprint:$fingerprint},buckets:{databases:$databases,longhorn:$longhorn,velero:$velero,management:$management,pbs:$pbs},vm:{vm_id:$vm_id,node:$node,datastore:$datastore,data_disk_gb:$data_disk_gb,ip_address:$ip_address,ssh_private_key:$ssh_private_key,status:"ready"}}' >"$profile_file"
chmod 0600 "$profile_file"
log "Provisioned dedicated SeaweedFS backup VM ${vm_id} on ${node_name}"
