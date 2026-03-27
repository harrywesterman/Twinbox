#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n '{placeholder: true}' >"$STEP_RESULT_FILE"
fi
