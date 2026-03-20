#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${TWINBOX_HOST_CRON_DIR:?missing TWINBOX_HOST_CRON_DIR}"
: "${TWINBOX_HOST_REPO_ROOT:?missing TWINBOX_HOST_REPO_ROOT}"

cron_file="${TWINBOX_HOST_CRON_DIR}/twinbox-management-updates"
enabled="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.enabled')"
hour="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.schedule_hour')"
minute="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.schedule_minute')"

mkdir -p "$TWINBOX_HOST_CRON_DIR"

if [[ "$enabled" == "true" ]]; then
  quoted_repo_root="$(printf '%q' "$TWINBOX_HOST_REPO_ROOT")"
  quoted_cron_file="$(printf '%q' "$cron_file")"
  cat >"$cron_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${minute} ${hour} * * * root cd ${quoted_repo_root} && git fetch --all --prune && git pull --ff-only origin main && docker compose pull && docker compose up -d >> ${quoted_cron_file}.log 2>&1
EOF
  chmod 0644 "$cron_file"
else
  rm -f "$cron_file"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cron_file "$cron_file" \
    --argjson enabled "$enabled" \
    --argjson schedule_hour "$hour" \
    --argjson schedule_minute "$minute" \
    '{
      cron_file: $cron_file,
      enabled: $enabled,
      schedule_hour: $schedule_hour,
      schedule_minute: $schedule_minute
    }' >"$STEP_RESULT_FILE"
fi
