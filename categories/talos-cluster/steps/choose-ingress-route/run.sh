#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

ingress_route="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ingress_route')"

case "$ingress_route" in
  wiredoor|cloudflare-tunnel|metallb|tailscale) ;;
  *)
    fail "Unsupported ingress route: $ingress_route"
    ;;
esac

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Selected ingress route: $ingress_route"

cluster_file="$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
if [[ -f "$cluster_file" ]]; then
  tmp_file="$(mktemp)"
  jq --arg ingress_route "$ingress_route" '.selected_ingress_route = $ingress_route' "$cluster_file" > "$tmp_file"
  mv "$tmp_file" "$cluster_file"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "selected_ingress_route": "$ingress_route",
  "cluster_id": "$cluster_id"
}
EOF
fi
