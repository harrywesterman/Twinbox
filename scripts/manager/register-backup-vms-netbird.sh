#!/usr/bin/env bash
set -euo pipefail

: "${TWINBOX_CLUSTER_ID:?missing TWINBOX_CLUSTER_ID}"
: "${NETBIRD_SETUP_KEY:?missing NETBIRD_SETUP_KEY}"
: "${NETBIRD_MANAGEMENT_URL:?missing NETBIRD_MANAGEMENT_URL}"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"

register_profile() {
  local profile="$1" hostname="$2" ip key
  [[ -s "$profile" ]] || return 0
  ip="$(jq -r '.vm.ip_address // .ip_address // empty' "$profile")"
  key="$(jq -r '.vm.ssh_private_key // .ssh_private_key // empty' "$profile")"
  [[ -n "$ip" && -s "$key" ]] || return 0
  ssh -i "$key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "twinbox@${ip}" \
    "if ! command -v netbird >/dev/null; then curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh; fi; sudo netbird up --management-url '${NETBIRD_MANAGEMENT_URL}' --setup-key '${NETBIRD_SETUP_KEY}' --hostname '${hostname}'"
}

register_profile "${BOOTSTRAP_ROOT}/secrets/cluster/${TWINBOX_CLUSTER_ID}/backup-storage/metadata.json" "twinbox-${TWINBOX_CLUSTER_ID}-backup-s3"
register_profile "${BOOTSTRAP_ROOT}/secrets/cluster/${TWINBOX_CLUSTER_ID}/pbs/metadata.json" "twinbox-${TWINBOX_CLUSTER_ID}-pbs"
