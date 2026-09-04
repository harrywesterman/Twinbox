#!/usr/bin/env bash

externalsecret_sync_token() {
  jq -r '[.status.refreshTime // "", .status.syncedResourceVersion // ""] | join("|")'
}

externalsecret_is_ready() {
  jq -r '[.status.conditions[]? | select(.type == "Ready") | .status] | first // "False"'
}

refresh_externalsecret_if_exists() {
  local namespace="$1"
  local resource="$2"
  local stamp="$3"
  local attempts="${TWINBOX_EXTERNAL_SECRET_REFRESH_ATTEMPTS:-120}"
  local poll_seconds="${TWINBOX_EXTERNAL_SECRET_REFRESH_POLL_SECONDS:-5}"
  local before_json before_token current_json current_token ready attempt

  if ! before_json="$(kubectl -n "$namespace" get "$resource" -o json 2>/dev/null)"; then
    echo "sync-twinbox-ai-config: ${resource} not found in ${namespace}, skipping refresh"
    return 0
  fi

  before_token="$(printf '%s' "$before_json" | externalsecret_sync_token)"
  kubectl -n "$namespace" annotate "$resource" \
    force-sync="$stamp" --overwrite >/dev/null

  for attempt in $(seq 1 "$attempts"); do
    current_json="$(kubectl -n "$namespace" get "$resource" -o json 2>/dev/null || true)"
    if [[ -n "$current_json" ]]; then
      current_token="$(printf '%s' "$current_json" | externalsecret_sync_token)"
      ready="$(printf '%s' "$current_json" | externalsecret_is_ready)"
      if [[ "$ready" == "True" && -n "$current_token" && "$current_token" != "$before_token" ]]; then
        return 0
      fi
    fi

    sleep "$poll_seconds"
  done

  echo "sync-twinbox-ai-config: ${resource} in ${namespace} did not refresh after ${attempts} attempts" >&2
  return 1
}
