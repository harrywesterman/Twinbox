#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

for attempt in $(seq 1 120); do
  if kubectl -n traefik get ingressroute/traefik-dashboard >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/longhorn >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: management console ingress routes did not appear in time" >&2
    exit 1
  fi
  sleep 5
done

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg traefik_route "traefik-dashboard" \
    --arg longhorn_route "longhorn" \
    '{
      traefik_route: $traefik_route,
      longhorn_route: $longhorn_route
    }' >"$STEP_RESULT_FILE"
fi
