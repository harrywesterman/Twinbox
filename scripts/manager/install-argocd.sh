#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ -n "${KUBECONFIG_FILE:-}" ]] || { usage; fail "KUBECONFIG_FILE is required"; }
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"

require_cmd kubectl

export KUBECONFIG="$KUBECONFIG_FILE"

log "Bootstrapping Argo CD"
bash "$WORKSPACE_ROOT/gitops/install.sh"
