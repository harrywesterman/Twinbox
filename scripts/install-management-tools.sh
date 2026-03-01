#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/opt/twinbox/.env"

usage() {
  cat <<'USAGE'
Usage: install-management-tools.sh [--env-file /path/to/.env]
USAGE
}

log() {
  printf '[install-management-tools] %s\n' "$1"
}

fail() {
  printf '[install-management-tools] ERROR: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      [[ $# -ge 2 ]] || fail "--env-file requires a value"
      ENV_FILE="$2"
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

[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
[[ "$(uname -s)" == "Linux" ]] || fail "Only Linux is supported"
[[ "$(uname -m)" == "x86_64" ]] || fail "Only amd64/x86_64 is supported"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required_vars=(TALOSCTL_VERSION KUBECTL_VERSION HELM_VERSION)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || fail "Missing required variable in ${ENV_FILE}: ${var}"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_cmd curl
require_cmd sha256sum
require_cmd tar
require_cmd install

normalize_version() {
  local raw="${1#v}"
  printf '%s' "$raw"
}

verify_checksum() {
  local file="$1"
  local expected="$2"
  local actual=""

  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "Checksum mismatch for ${file}"
}

download_to() {
  local url="$1"
  local dest="$2"
  curl -fsSL "$url" -o "$dest"
}

install_talosctl() {
  local version
  local base_url
  local bin_name="talosctl-linux-amd64"
  local bin_path="$tmp_dir/$bin_name"
  local checksum_url=""
  local checksum_line=""
  local expected_checksum=""

  version="$(normalize_version "$TALOSCTL_VERSION")"
  base_url="https://github.com/siderolabs/talos/releases/download/v${version}"

  log "Installing talosctl v${version}"
  download_to "${base_url}/${bin_name}" "$bin_path"

  checksum_url="${base_url}/${bin_name}.sha256sum"
  checksum_line="$(curl -fsSL "$checksum_url" 2>/dev/null || true)"
  if [[ -n "$checksum_line" ]]; then
    expected_checksum="$(printf '%s\n' "$checksum_line" | awk '{print $1}' | head -n1)"
    [[ -n "$expected_checksum" ]] || fail "Could not parse talosctl checksum"
    verify_checksum "$bin_path" "$expected_checksum"
  else
    log "talosctl checksum not available; skipping checksum verification"
  fi

  install -m 0755 "$bin_path" /usr/local/bin/talosctl
}

install_kubectl() {
  local version
  local base_url
  local bin_path="$tmp_dir/kubectl"
  local checksum_path="$tmp_dir/kubectl.sha256"
  local expected_checksum=""

  version="$(normalize_version "$KUBECTL_VERSION")"
  base_url="https://dl.k8s.io/release/v${version}/bin/linux/amd64"

  log "Installing kubectl v${version}"
  download_to "${base_url}/kubectl" "$bin_path"
  download_to "${base_url}/kubectl.sha256" "$checksum_path"
  expected_checksum="$(tr -d '[:space:]' < "$checksum_path")"
  [[ -n "$expected_checksum" ]] || fail "Could not parse kubectl checksum"
  verify_checksum "$bin_path" "$expected_checksum"

  install -m 0755 "$bin_path" /usr/local/bin/kubectl
}

install_helm() {
  local version
  local tar_name
  local base_url="https://get.helm.sh"
  local tar_path
  local checksum_path
  local checksum_line
  local expected_checksum

  version="$(normalize_version "$HELM_VERSION")"
  tar_name="helm-v${version}-linux-amd64.tar.gz"
  tar_path="$tmp_dir/$tar_name"
  checksum_path="$tmp_dir/${tar_name}.sha256"

  log "Installing helm v${version}"
  download_to "${base_url}/${tar_name}" "$tar_path"
  download_to "${base_url}/${tar_name}.sha256" "$checksum_path"
  checksum_line="$(tr -d '[:space:]' < "$checksum_path")"
  expected_checksum="$(printf '%s\n' "$checksum_line" | awk '{print $1}')"
  [[ -n "$expected_checksum" ]] || fail "Could not parse helm checksum"
  verify_checksum "$tar_path" "$expected_checksum"

  tar -xzf "$tar_path" -C "$tmp_dir"
  install -m 0755 "$tmp_dir/linux-amd64/helm" /usr/local/bin/helm
}

extract_semver() {
  local value="$1"
  local parsed=""
  parsed="$(printf '%s\n' "$value" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [[ -n "$parsed" ]] || fail "Unable to parse semantic version from: $value"
  printf '%s' "${parsed#v}"
}

verify_versions() {
  local talos_output=""
  local kubectl_output=""
  local helm_output=""
  local talos_actual=""
  local kubectl_actual=""
  local helm_actual=""
  local talos_expected
  local kubectl_expected
  local helm_expected

  talos_output="$(/usr/local/bin/talosctl version --client 2>&1 || true)"
  kubectl_output="$(/usr/local/bin/kubectl version --client --output=yaml 2>&1 || true)"
  helm_output="$(/usr/local/bin/helm version --short 2>&1 || true)"

  talos_actual="$(extract_semver "$talos_output")"
  kubectl_actual="$(extract_semver "$kubectl_output")"
  helm_actual="$(extract_semver "$helm_output")"

  talos_expected="$(normalize_version "$TALOSCTL_VERSION")"
  kubectl_expected="$(normalize_version "$KUBECTL_VERSION")"
  helm_expected="$(normalize_version "$HELM_VERSION")"

  [[ "$talos_actual" == "$talos_expected" ]] || fail "talosctl version mismatch: expected v${talos_expected}, got v${talos_actual}"
  [[ "$kubectl_actual" == "$kubectl_expected" ]] || fail "kubectl version mismatch: expected v${kubectl_expected}, got v${kubectl_actual}"
  [[ "$helm_actual" == "$helm_expected" ]] || fail "helm version mismatch: expected v${helm_expected}, got v${helm_actual}"

  log "Installed versions: talosctl=v${talos_actual}, kubectl=v${kubectl_actual}, helm=v${helm_actual}"
}

install_talosctl
install_kubectl
install_helm
verify_versions

log "Done"
