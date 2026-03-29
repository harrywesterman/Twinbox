#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: sync-openbao-global-secret.sh --secret-name NAME --json-file PATH [--required-keys key1,key2]
USAGE
}

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

SECRET_NAME=""
JSON_FILE=""
REQUIRED_KEYS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret-name)
      SECRET_NAME="$2"
      shift 2
      ;;
    --json-file)
      JSON_FILE="$2"
      shift 2
      ;;
    --required-keys)
      REQUIRED_KEYS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      openbao_fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$SECRET_NAME" ]] || openbao_fail "--secret-name is required"
[[ -n "$JSON_FILE" ]] || openbao_fail "--json-file is required"

required_key_list=()
if [[ -n "$REQUIRED_KEYS" ]]; then
  IFS=',' read -r -a raw_required_key_list <<<"$REQUIRED_KEYS"
  for key in "${raw_required_key_list[@]}"; do
    trimmed_key="$(printf '%s' "$key" | xargs)"
    [[ -n "$trimmed_key" ]] || continue
    required_key_list+=("$trimmed_key")
  done
fi

openbao_sync_global_secret_file "$SECRET_NAME" "$JSON_FILE" "${required_key_list[@]}"
