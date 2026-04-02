#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: render-cluster-config-map.sh --zone-name NAME
USAGE
}

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ZONE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone-name)
      ZONE_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$ZONE_NAME" ]] || { usage; echo "ERROR: --zone-name is required" >&2; exit 1; }

tick='`'

config_map_file="$WORKSPACE_ROOT/gitops/platform/cluster-config/configmap.yaml"
mkdir -p "$(dirname "$config_map_file")"

cat >"$config_map_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  namespace: argocd
data:
  ZONE_NAME: "$ZONE_NAME"
  ARGOCD_MATCH: "Host(${tick}argocd.$ZONE_NAME${tick})"
  AUTHENTIK_MATCH: "Host(${tick}authentik.$ZONE_NAME${tick})"
  HEADLAMP_MATCH: "Host(${tick}headlamp.$ZONE_NAME${tick})"
  GRAFANA_MATCH: "Host(${tick}grafana.$ZONE_NAME${tick})"
  PROMETHEUS_MATCH: "Host(${tick}prometheus.$ZONE_NAME${tick})"
  NTFY_MATCH: "Host(${tick}ntfy.$ZONE_NAME${tick})"
  HOMEPAGE_MATCH: "Host(${tick}homepage.$ZONE_NAME${tick})"
  WHOAMI_MATCH: "Host(${tick}whoami.$ZONE_NAME${tick})"
  TRAEFIK_DASHBOARD_MATCH: "Host(${tick}traefik.$ZONE_NAME${tick}) && (PathPrefix(${tick}/api${tick}) || PathPrefix(${tick}/dashboard${tick}))"
  HOMEPAGE_ALLOWED_HOSTS: "homepage.$ZONE_NAME"
  HOMEPAGE_BOOKMARKS_YAML: |
    - Platform:
        - Argo CD:
            - href: https://argocd.$ZONE_NAME
              description: GitOps control plane
        - Traefik:
            - href: https://traefik.$ZONE_NAME
              description: Ingress controller
        - Authentik:
            - href: https://authentik.$ZONE_NAME
              description: Identity provider
        - Headlamp:
            - href: https://headlamp.$ZONE_NAME
              description: Kubernetes dashboard
        - Grafana:
            - href: https://grafana.$ZONE_NAME
              description: Metrics and dashboards
        - Prometheus:
            - href: https://prometheus.$ZONE_NAME
              description: Metrics collection and alerting
        - ntfy:
            - href: https://ntfy.$ZONE_NAME
              description: Push notification service
        - Wiredoor:
            href: https://argocd.$ZONE_NAME
            description: Alternate operator entrypoint
    - Apps:
        - Whoami:
            href: https://whoami.$ZONE_NAME
            description: Minimal ingress check
        - Homepage:
            href: https://homepage.$ZONE_NAME
            description: Cluster landing page
  HOMEPAGE_SERVICES_YAML: |
    - Platform:
        - Argo CD:
            href: https://argocd.$ZONE_NAME
            description: GitOps control plane
        - Traefik:
            href: https://traefik.$ZONE_NAME
            description: Ingress controller
        - Authentik:
            href: https://authentik.$ZONE_NAME
            description: Identity provider
        - Headlamp:
            href: https://headlamp.$ZONE_NAME
            description: Kubernetes dashboard
        - Grafana:
            href: https://grafana.$ZONE_NAME
            description: Metrics and dashboards
    - Apps:
        - Whoami:
            href: https://whoami.$ZONE_NAME
            description: Minimal ingress check
        - Homepage:
            href: https://homepage.$ZONE_NAME
            description: Cluster landing page
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rendered cluster-config ConfigMap to $config_map_file"
