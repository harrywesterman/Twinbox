#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
exec "$WORKSPACE_ROOT/categories/talos-cluster/steps/install-zulip/run.sh" "$@"
