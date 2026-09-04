#!/usr/bin/env bash
set -euo pipefail
: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
exec bash "$WORKSPACE_ROOT/scripts/manager/install-proxmox-backup-server.sh"
