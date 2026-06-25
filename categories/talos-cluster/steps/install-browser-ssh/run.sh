#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${TWINBOX_TALOSCONFIG_FILE:?missing TWINBOX_TALOSCONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"

bash "$WORKSPACE_ROOT/scripts/manager/setup-opkssh-authentik.sh"
bash "$WORKSPACE_ROOT/scripts/manager/setup-termix-authentik.sh"
bash "$WORKSPACE_ROOT/scripts/manager/setup-termix.sh"
