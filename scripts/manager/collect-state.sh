#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 --cluster-id ID --data-dir DIR"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" && -n "${DATA_DIR:-}" ]] || { usage; exit 1; }

cluster_file="$DATA_DIR/clusters/${CLUSTER_ID}.json"
[[ -f "$cluster_file" ]] || { echo "cluster not found"; exit 1; }

cat "$cluster_file"
