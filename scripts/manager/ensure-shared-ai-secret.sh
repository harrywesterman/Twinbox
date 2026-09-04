#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

read_error_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-ai-read-error-XXXXXX")"
secret_file=""

cleanup() {
  rm -f "$read_error_file"
  if [[ -n "$secret_file" ]]; then
    rm -f "$secret_file"
  fi
}
trap cleanup EXIT

set +e
openbao_read_global_secret_json twinbox-ai >/dev/null 2>"$read_error_file"
read_status=$?
set -e

if [[ "$read_status" -eq 0 ]]; then
  echo "ensure-shared-ai-secret: twinbox-ai secret already exists"
  exit 0
fi

if ! grep -Eq '(^|[^0-9])404([^0-9]|$)' "$read_error_file"; then
  cat "$read_error_file" >&2
  echo "ensure-shared-ai-secret: unable to determine whether twinbox-ai exists" >&2
  exit "$read_status"
fi

secret_file="$(mktemp "${TMPDIR:-/tmp}/twinbox-ai-empty-XXXXXX")"

jq -n \
  '{
    OPENAI_API_BASE_URL: "",
    OPENAI_BASE_URL: "",
    OPENAI_API_KEY: "",
    DEFAULT_MODELS: "",
    INFERENCE_TEXT_MODEL: "",
    INFERENCE_IMAGE_MODEL: "",
    PAPERLESS_AI_ENABLED: "false",
    PAPERLESS_AI_LLM_BACKEND: "",
    PAPERLESS_AI_LLM_MODEL: "",
    PAPERLESS_AI_LLM_API_KEY: "",
    PAPERLESS_AI_LLM_ENDPOINT: "",
    PAPERLESS_AI_LLM_ALLOW_INTERNAL_ENDPOINTS: "true",
    OPENCODE_CONFIG_JSON: "{}"
  }' >"$secret_file"

echo "ensure-shared-ai-secret: seeding empty twinbox-ai secret"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name twinbox-ai \
  --json-file "$secret_file"
