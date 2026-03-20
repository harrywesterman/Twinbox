#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../config/pinned-defaults.sh"

usage() {
  cat <<'USAGE'
Usage: get-talos-image-factory.sh [--preset vanilla|qemu-guest-agent] [--version vX.Y.Z] [--arch amd64] [--platform cloud-server] [--output id|url|shell|json]
USAGE
}

fail() {
  printf '[get-talos-image-factory] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

preset="vanilla"
version="${PINNED_TALOS_VERSION}"
arch="${PINNED_TALOS_IMAGE_ARCH}"
platform="${PINNED_TALOS_IMAGE_PLATFORM}"
output="shell"
extensions=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      [[ $# -ge 2 ]] || fail "--preset requires a value"
      preset="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      version="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || fail "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || fail "--platform requires a value"
      platform="$2"
      shift 2
      ;;
    --extension)
      [[ $# -ge 2 ]] || fail "--extension requires a value"
      extensions+=("$2")
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a value"
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$preset" in
  vanilla)
    ;;
  qemu-guest-agent)
    extensions+=("siderolabs/qemu-guest-agent")
    ;;
  *)
    fail "Unknown preset: $preset"
    ;;
esac

require_cmd curl
require_cmd jq

payload="$(
  if [[ "${#extensions[@]}" -eq 0 ]]; then
    cat <<'EOF'
customization: {}
EOF
  else
    {
      printf 'customization:\n'
      printf '  systemExtensions:\n'
      printf '    officialExtensions:\n'
      for extension in "${extensions[@]}"; do
        printf '      - %s\n' "$extension"
      done
    }
  fi
)"

response="$(
  printf '%s' "$payload" | curl -fsSL \
    -X POST \
    -H "Content-Type: application/yaml" \
    --data-binary @- \
    "https://factory.talos.dev/schematics"
)"

schematic_id="$(printf '%s' "$response" | jq -r '.id // empty')"
[[ -n "$schematic_id" ]] || fail "Factory response did not include an id"

image_url="https://factory.talos.dev/image/${schematic_id}/${version}/metal-${arch}.iso"
download_url="$(
  curl -fsSL -o /dev/null -w '%{url_effective}' "$image_url"
)"

case "$output" in
  id)
    printf '%s\n' "$schematic_id"
    ;;
  url)
    printf '%s\n' "$image_url"
    ;;
  shell)
    printf 'TALOS_IMAGE_SCHEMATIC=%s\n' "$schematic_id"
    printf 'TALOS_IMAGE_FACTORY_URL=%s\n' "$image_url"
    printf 'TALOS_IMAGE_DOWNLOAD_URL=%s\n' "$download_url"
    ;;
  json)
    jq -n \
      --arg id "$schematic_id" \
      --arg version "$version" \
      --arg arch "$arch" \
      --arg platform "$platform" \
      --arg url "$image_url" \
      --arg download_url "$download_url" \
      '{
        schematic_id: $id,
        version: $version,
        arch: $arch,
        platform: $platform,
        image_url: $url,
        download_url: $download_url
      }'
    ;;
  *)
    fail "Unknown output format: $output"
    ;;
esac
