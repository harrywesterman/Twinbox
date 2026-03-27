#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"

bash scripts/manager/apply-cluster.sh \
  --cluster-id "$(printf '%s' "$cluster_json" | jq -r '.id')" \
  --name "$(printf '%s' "$cluster_json" | jq -r '.name')" \
  --controlplane-count "$(printf '%s' "$cluster_json" | jq -r '.controlplane_count')" \
  --worker-count "$(printf '%s' "$cluster_json" | jq -r '.worker_count')" \
  --cpu-cores "$(printf '%s' "$cluster_json" | jq -r '.cpu_cores')" \
  --memory-mb "$(printf '%s' "$cluster_json" | jq -r '.memory_mb')" \
  --disk-gb "$(printf '%s' "$cluster_json" | jq -r '.disk_gb')" \
  --bridge "$(printf '%s' "$cluster_json" | jq -r '.bridge')" \
  --start-vmid "$(printf '%s' "$cluster_json" | jq -r '.start_vmid')" \
  --start-ip "$(printf '%s' "$cluster_json" | jq -r '.start_ip')" \
  --vip-ip "$(printf '%s' "$cluster_json" | jq -r '.vip_ip')" \
  --node-prefix-length "$(printf '%s' "$cluster_json" | jq -r '.node_prefix_length')" \
  --gateway-ip "$(printf '%s' "$cluster_json" | jq -r '.gateway_ip')" \
  --dns-servers "$(printf '%s' "$cluster_json" | jq -r '.dns_servers | join(",")')" \
  --dns-domain "$(printf '%s' "$cluster_json" | jq -r '.dns_domain')" \
  --vm-node-map "$(printf '%s' "$cluster_json" | jq -c '.vm_node_map // {}')" \
  --proxmox-node "$(printf '%s' "$cluster_json" | jq -r '.metadata.proxmox_node')" \
  --storage-pool "$(printf '%s' "$cluster_json" | jq -r '.metadata.storage_pool')" \
  --file-datastore "$(printf '%s' "$cluster_json" | jq -r '.metadata.file_datastore')" \
  --data-dir "$MANAGER_DATA_DIR"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cluster_file="$MANAGER_DATA_DIR/clusters/$(printf '%s' "$cluster_json" | jq -r '.id').json"
  jq '{
    cluster_id: .id,
    cluster_status: .status,
    secret_refs: .metadata.secret_refs,
    iac_workdir: .iac.workdir,
    state_path: .iac.state_path
  }' "$cluster_file" >"$STEP_RESULT_FILE"
fi
