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
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rendered cluster-config ConfigMap to $config_map_file"
