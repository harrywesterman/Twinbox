#!/usr/bin/env bash
set -euo pipefail
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"
: "${TWINBOX_CLUSTER_ID:?cluster id required}"
export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_FILE:-${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/cluster/${TWINBOX_CLUSTER_ID}/kubeconfig/kubeconfig}}"
if [[ ! -s "$KUBECONFIG" ]]; then
  echo 'Backup VM monitoring deferred until Kubernetes monitoring is installed'
  exit 0
fi
export BESZEL_VERSION="${PINNED_BESZEL_VERSION}"
exec python3 "$WORKSPACE_ROOT/scripts/manager/register-backup-vm-monitoring.py"
