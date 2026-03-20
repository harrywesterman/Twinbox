#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
controlplane_ips="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.controlplane_ips | join(",")')"
worker_ips="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.worker_ips | join(",")')"
vip_ip="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.vip_ip')"

bash scripts/manager/bootstrap-talos.sh \
  --cluster-id "$(printf '%s' "$cluster_json" | jq -r '.id')" \
  --name "$(printf '%s' "$cluster_json" | jq -r '.name')" \
  --vip-ip "$vip_ip" \
  --controlplane-ips "$controlplane_ips" \
  --worker-ips "$worker_ips" \
  --data-dir "$MANAGER_DATA_DIR"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  printf '%s' "$cluster_json" | jq '{ cluster_id: .id }' >"$STEP_RESULT_FILE"
fi
