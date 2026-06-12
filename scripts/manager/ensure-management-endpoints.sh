#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PLATFORM_DIR="$WORKSPACE_ROOT/gitops/platform"

source "$SCRIPT_DIR/management-ip.sh"

mgmt_ip="${MANAGEMENT_VM_IP:-}"
if [[ -z "$mgmt_ip" ]]; then
  mgmt_ip="$(resolve_management_vm_ip)" || fail "Unable to resolve management VM IP"
fi

proxmox_ip="${PROXMOX_HOST:-}"
[[ -n "$proxmox_ip" ]] || fail "PROXMOX_HOST is required to render management endpoints"

for endpoint_file in proxmox-endpoints.yaml seaweedfs-endpoints.yaml webwizard-endpoints.yaml beszel-endpoints.yaml; do
  template="$PLATFORM_DIR/management-consoles/$endpoint_file"
  [[ -f "$template" ]] || fail "Endpoint template not found: $template"

  rendered=$(sed \
    -e "s/__PROXMOX_HOST_IP__/${proxmox_ip}/g" \
    -e "s/__MGMT_HOST_IP__/${mgmt_ip}/g" \
    "$template")

  log "Applying ${endpoint_file} (proxmox=${proxmox_ip}, mgmt=${mgmt_ip})"
  kubectl apply -f - <<<"$rendered"
done

if [[ -x "$SCRIPT_DIR/sync-manager-api-node-allowlist.sh" ]]; then
  "$SCRIPT_DIR/sync-manager-api-node-allowlist.sh" || log "manager-api node allowlist sync skipped or failed"
fi
