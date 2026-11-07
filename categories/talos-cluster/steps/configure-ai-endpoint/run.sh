#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_id="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.id // empty')"
[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

config_dir="${TWINBOX_BOOTSTRAP_DIR}/secrets/cluster/${cluster_id}/ai-endpoint"
config_file="${config_dir}/config.json"

base_url="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ai_base_url // empty')"
model="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ai_model // empty')"
display_name="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.ai_display_name // empty')"

if [[ -z "$base_url" && -z "$model" ]]; then
  log "No AI endpoint configured; the AI beheerteam installs without one and can be configured later in the Portal"
  exit 0
fi

[[ -n "$base_url" ]] || fail "AI base URL is required when a model is configured"
[[ -n "$model" ]] || fail "AI model is required when a base URL is configured"
[[ "$base_url" =~ ^https?:// ]] || fail "AI base URL must start with http:// or https://"
base_url="${base_url%/}"

mkdir -p "$config_dir"
chmod 0700 "$config_dir"
jq -n \
  --arg display_name "$display_name" \
  --arg base_url "$base_url" \
  --arg model "$model" \
  '{displayName: $display_name, baseUrl: $base_url, model: $model, timeoutMs: 60000}' \
  >"$config_file"
chmod 0600 "$config_file"

log "Stored AI endpoint ${base_url} (model ${model}) for cluster ${cluster_id}"
