#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

archive_name="k9s_Linux_amd64.tar.gz"
archive_path="$tmp_dir/$archive_name"
download_url="https://github.com/derailed/k9s/releases/latest/download/${archive_name}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd tar
require_cmd install

printf 'Downloading k9s from %s\n' "$download_url"
curl -fsSL "$download_url" -o "$archive_path"

tar -xzf "$archive_path" -C "$tmp_dir"

binary_path="$tmp_dir/k9s"
if [[ ! -f "$binary_path" ]]; then
  printf 'k9s binary not found in archive\n' >&2
  exit 1
fi

sudo install -m 0755 "$binary_path" /usr/local/bin/k9s

k9s version
