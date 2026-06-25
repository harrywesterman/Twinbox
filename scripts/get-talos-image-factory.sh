#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../config/pinned-defaults.sh"

usage() {
  cat <<'USAGE'
Usage: get-talos-image-factory.sh [--preset vanilla|qemu-guest-agent] [--version vX.Y.Z] [--arch amd64] [--platform cloud-server] [--installer-only] [--output id|url|shell|json|extensions]
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
installer_only="false"
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
    --installer-only)
      installer_only="true"
      shift
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
    extensions+=("siderolabs/iscsi-tools")
    extensions+=("siderolabs/util-linux-tools")
    ;;
  *)
    fail "Unknown preset: $preset"
    ;;
esac

if [[ "$output" == "extensions" ]]; then
  printf '%s\n' "${extensions[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
  exit 0
fi

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

# Use the compressed bootable Talos disk image rather than the ISO installer path.
image_url="https://factory.talos.dev/image/${schematic_id}/${version}/metal-${arch}.raw.xz"
installer_image="factory.talos.dev/metal-installer/${schematic_id}:${version}"
download_url=""
if [[ "$installer_only" != "true" ]]; then
  download_url="$(
    curl -fsSL -o /dev/null -w '%{url_effective}' "$image_url"
  )"
fi

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
    printf 'TALOS_IMAGE_DISK_URL=%s\n' "$download_url"
    printf 'TALOS_IMAGE_DOWNLOAD_URL=%s\n' "$download_url"
    printf 'TALOS_IMAGE_INSTALLER=%s\n' "$installer_image"
    ;;
  json)
    jq -n \
      --arg id "$schematic_id" \
      --arg version "$version" \
      --arg arch "$arch" \
      --arg platform "$platform" \
      --arg url "$image_url" \
      --arg disk_url "$download_url" \
      --arg installer_image "$installer_image" \
      '{
        schematic_id: $id,
        version: $version,
        arch: $arch,
        platform: $platform,
        image_url: $url,
        disk_url: $disk_url,
        installer_image: $installer_image,
        download_url: $disk_url
      }'
    ;;
  *)
    fail "Unknown output format: $output"
    ;;
esac
