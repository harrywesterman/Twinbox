#!/usr/bin/env bash
set -euo pipefail
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
exec node "$WORKSPACE_ROOT/manager-worker/src/gatus-sync.mjs" install
