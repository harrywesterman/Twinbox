#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/opt/twinbox/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"

source_pinned_defaults() {
  local candidate=""
  if [[ -f "$SCRIPT_DIR/../config/pinned-defaults.sh" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/../config/pinned-defaults.sh"
    return 0
  fi

  local candidates=(
    "$SCRIPT_DIR/../../config/pinned-defaults.sh"
    "${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/config/pinned-defaults.sh"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      # shellcheck disable=SC1090
      source "$candidate"
      return 0
    fi
  done

  fail "Unable to locate config/pinned-defaults.sh"
}

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

export HOME="${HOME:-/root}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Re-load the repo pins so stale values in .env cannot override the canonical versions.
source_pinned_defaults

[[ -n "${PINNED_K9S_VERSION:-}" ]] || fail "Missing required variable in ${ENV_FILE}: PINNED_K9S_VERSION"
[[ -n "${PINNED_KUBECTL_VERSION:-}" ]] || fail "Missing required variable in ${SCRIPT_DIR}/../config/pinned-defaults.sh: PINNED_KUBECTL_VERSION"
[[ -n "${PINNED_HELM_VERSION:-}" ]] || fail "Missing required variable in ${SCRIPT_DIR}/../config/pinned-defaults.sh: PINNED_HELM_VERSION"
[[ -n "${PINNED_ARGOCD_VERSION:-}" ]] || fail "Missing required variable in ${SCRIPT_DIR}/../config/pinned-defaults.sh: PINNED_ARGOCD_VERSION"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_cmd curl
require_cmd apt-get
require_cmd sha256sum
require_cmd tar
require_cmd install

normalize_version() {
  local raw="${1#v}"
  printf '%s' "$raw"
}

version_gte() {
  local left="$1"
  local right="$2"
  [[ "$(printf '%s\n%s\n' "$right" "$left" | sort -V | head -n1)" == "$right" ]]
}

ensure_talos_cpu_compatibility() {
  local talos_version=""
  local cpu_flags=""
  local required_flags=(ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm)
  local missing_flags=()
  local flag=""

  talos_version="$(normalize_version "$PINNED_TALOS_VERSION")"
  if ! version_gte "$talos_version" "1.7.0"; then
    return 0
  fi

  cpu_flags="$(awk -F':' '/^flags[[:space:]]*:/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [[ -n "$cpu_flags" ]] || fail "Could not read CPU flags from /proc/cpuinfo"

  for flag in "${required_flags[@]}"; do
    if ! printf '%s\n' "$cpu_flags" | grep -qw "$flag"; then
      missing_flags+=("$flag")
    fi
  done

  if [[ "${#missing_flags[@]}" -gt 0 ]]; then
    fail "CPU misses x86-64-v2 flags needed by talosctl v${talos_version}: ${missing_flags[*]}. In Proxmox, set VM CPU type to 'host' (or x86-64-v2-AES), then cold reboot/recreate the VM."
  fi
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
  curl --fail --silent --show-error --location \
    --retry 5 --retry-delay 2 --retry-max-time 120 --retry-all-errors \
    "$url" -o "$dest"
}

install_talosctl() {
  local version
  local base_url
  local bin_name="talosctl-linux-amd64"
  local bin_path="$tmp_dir/$bin_name"
  local checksum_url=""
  local checksum_line=""
  local expected_checksum=""

  version="$(normalize_version "$PINNED_TALOS_VERSION")"
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

install_tofu() {
  local version
  local archive_name
  local archive_path
  local checksum_url=""
  local checksum_text=""
  local expected_checksum=""

  version="$(normalize_version "$PINNED_OPENTOFU_VERSION")"
  archive_name="tofu_${version}_linux_amd64.tar.gz"
  archive_path="$tmp_dir/$archive_name"

  log "Installing OpenTofu v${version}"
  download_to "https://github.com/opentofu/opentofu/releases/download/v${version}/${archive_name}" "$archive_path"

  checksum_url="https://github.com/opentofu/opentofu/releases/download/v${version}/tofu_${version}_SHA256SUMS"
  checksum_text="$(curl -fsSL "$checksum_url" 2>/dev/null || true)"
  if [[ -n "$checksum_text" ]]; then
    expected_checksum="$(printf '%s\n' "$checksum_text" | awk -v target="$archive_name" '$2 == target { print $1; exit }')"
    [[ -n "$expected_checksum" ]] || fail "Could not parse OpenTofu checksum"
    verify_checksum "$archive_path" "$expected_checksum"
  else
    log "OpenTofu checksum not available; skipping checksum verification"
  fi

  tar -xzf "$archive_path" -C "$tmp_dir"
  install -m 0755 "$tmp_dir/tofu" /usr/local/bin/tofu
}

install_kubectl() {
  local version
  local base_url
  local bin_path="$tmp_dir/kubectl"
  local checksum_path="$tmp_dir/kubectl.sha256"
  local expected_checksum=""

  version="$(normalize_version "$PINNED_KUBECTL_VERSION")"
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

  version="$(normalize_version "$PINNED_HELM_VERSION")"
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

install_argocd() {
  local version
  local base_url
  local bin_name
  local bin_path
  local checksums_path
  local checksums_text=""
  local expected_checksum=""

  version="$(normalize_version "$PINNED_ARGOCD_VERSION")"
  base_url="https://github.com/argoproj/argo-cd/releases/download/v${version}"
  bin_name="argocd-linux-amd64"
  bin_path="$tmp_dir/$bin_name"
  checksums_path="$tmp_dir/cli_checksums.txt"

  log "Installing argocd v${version}"
  download_to "${base_url}/${bin_name}" "$bin_path"
  download_to "${base_url}/cli_checksums.txt" "$checksums_path"
  checksums_text="$(tr -d '\r' < "$checksums_path")"
  expected_checksum="$(printf '%s\n' "$checksums_text" | awk -v target="$bin_name" '$2 == target { print $1; exit }')"
  [[ -n "$expected_checksum" ]] || fail "Could not parse argocd checksum"
  verify_checksum "$bin_path" "$expected_checksum"

  install -m 0755 "$bin_path" /usr/local/bin/argocd
}

install_k9s() {
  local version
  local base_url
  local tar_name
  local tar_path
  local checksum_url=""
  local checksum_text=""
  local expected_checksum=""

  version="$(normalize_version "$PINNED_K9S_VERSION")"
  base_url="https://github.com/derailed/k9s/releases/download/v${version}"
  tar_name="k9s_Linux_amd64.tar.gz"
  tar_path="$tmp_dir/$tar_name"

  log "Installing k9s v${version}"
  download_to "${base_url}/${tar_name}" "$tar_path"

  checksum_url="${base_url}/checksums.txt"
  checksum_text="$(curl -fsSL "$checksum_url" 2>/dev/null || true)"
  if [[ -n "$checksum_text" ]]; then
    expected_checksum="$(printf '%s\n' "$checksum_text" | awk -v target="$tar_name" '$2 == target { print $1; exit }')"
    [[ -n "$expected_checksum" ]] || fail "Could not parse k9s checksum"
    verify_checksum "$tar_path" "$expected_checksum"
  else
    log "k9s checksum not available; skipping checksum verification"
  fi

  tar -xzf "$tar_path" -C "$tmp_dir"
  install -m 0755 "$tmp_dir/k9s" /usr/local/bin/k9s
}

ensure_openssl() {
  if command -v openssl >/dev/null 2>&1; then
    return 0
  fi

  log "Installing openssl"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y openssl >/dev/null
}

install_restic() {
  if command -v restic >/dev/null 2>&1; then
    log "restic already installed: $(restic version 2>/dev/null || printf 'unknown version')"
    return 0
  fi

  log "Installing restic"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y restic >/dev/null
  command -v restic >/dev/null 2>&1 || fail "restic install did not provide a restic binary"
}

install_wrappers() {
  local kubectl_wrapper="$tmp_dir/k"
  local talosctl_wrapper="$tmp_dir/t"

  cat > "$kubectl_wrapper" <<'EOF'
#!/bin/sh
exec kubectl "$@"
EOF

  cat > "$talosctl_wrapper" <<'EOF'
#!/bin/sh
exec talosctl "$@"
EOF

  install -m 0755 "$kubectl_wrapper" /usr/local/bin/k
  install -m 0755 "$talosctl_wrapper" /usr/local/bin/t
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
  local argocd_output=""
  local tofu_output=""
  local k9s_output=""
  local talos_actual=""
  local tofu_actual=""
  local kubectl_actual=""
  local helm_actual=""
  local argocd_actual=""
  local k9s_actual=""
  local talos_expected
  local tofu_expected
  local kubectl_expected
  local helm_expected
  local argocd_expected
  local k9s_expected

  talos_output="$(/usr/local/bin/talosctl version --client 2>&1)" || fail "talosctl version check failed: ${talos_output}"
  tofu_output="$(/usr/local/bin/tofu version 2>&1)" || fail "tofu version check failed: ${tofu_output}"
  kubectl_output="$(/usr/local/bin/kubectl version --client --output=yaml 2>&1)" || fail "kubectl version check failed: ${kubectl_output}"
  helm_output="$(/usr/local/bin/helm version --short 2>&1)" || fail "helm version check failed: ${helm_output}"
  argocd_output="$(/usr/local/bin/argocd version --client --short 2>&1)" || fail "argocd version check failed: ${argocd_output}"
  k9s_output="$(/usr/local/bin/k9s version --short 2>&1)" || fail "k9s version check failed: ${k9s_output}"

  talos_actual="$(extract_semver "$talos_output")"
  tofu_actual="$(extract_semver "$tofu_output")"
  kubectl_actual="$(extract_semver "$kubectl_output")"
  helm_actual="$(extract_semver "$helm_output")"
  argocd_actual="$(extract_semver "$argocd_output")"
  k9s_actual="$(extract_semver "$k9s_output")"

  talos_expected="$(normalize_version "$PINNED_TALOS_VERSION")"
  tofu_expected="$(normalize_version "$PINNED_OPENTOFU_VERSION")"
  kubectl_expected="$(normalize_version "$PINNED_KUBECTL_VERSION")"
  helm_expected="$(normalize_version "$PINNED_HELM_VERSION")"
  argocd_expected="$(normalize_version "$PINNED_ARGOCD_VERSION")"
  k9s_expected="$(normalize_version "$PINNED_K9S_VERSION")"

  [[ "$talos_actual" == "$talos_expected" ]] || fail "talosctl version mismatch: expected v${talos_expected}, got v${talos_actual}"
  [[ "$tofu_actual" == "$tofu_expected" ]] || fail "tofu version mismatch: expected v${tofu_expected}, got v${tofu_actual}"
  [[ "$kubectl_actual" == "$kubectl_expected" ]] || fail "kubectl version mismatch: expected v${kubectl_expected}, got v${kubectl_actual}"
  [[ "$helm_actual" == "$helm_expected" ]] || fail "helm version mismatch: expected v${helm_expected}, got v${helm_actual}"
  [[ "$argocd_actual" == "$argocd_expected" ]] || fail "argocd version mismatch: expected v${argocd_expected}, got v${argocd_actual}"
  [[ "$k9s_actual" == "$k9s_expected" ]] || fail "k9s version mismatch: expected v${k9s_expected}, got v${k9s_actual}"
  log "Installed versions: talosctl=v${talos_actual}, tofu=v${tofu_actual}, kubectl=v${kubectl_actual}, helm=v${helm_actual}, argocd=v${argocd_actual}, k9s=v${k9s_actual}"
}

configure_argocd_cli() {
  local bootstrap_file="$BOOTSTRAP_DIR/secrets/global/argocd-cli.json"
  local cluster_id=""
  local argocd_host=""
  local argocd_server=""
  local kubeconfig_file=""
  local config_dir="${HOME:-/root}/.config/argocd"
  local config_file="${config_dir}/config"
  local profile_file="/etc/profile.d/twinbox-argocd.sh"
  local argocd_opts="--grpc-web"
  local admin_password=""
  local login_ok="false"

  if [[ ! -f "$bootstrap_file" ]]; then
    log "Argo CD CLI bootstrap file not found; skipping CLI configuration"
    return 0
  fi

  cluster_id="$(jq -r '.CLUSTER_ID // empty' "$bootstrap_file")"
  argocd_host="$(jq -r '.ARGOCD_HOST // empty' "$bootstrap_file")"
  [[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from ${bootstrap_file}"
  [[ -n "$argocd_host" ]] || fail "Could not determine Argo CD host from ${bootstrap_file}"

  argocd_server="${argocd_host#https://}"
  kubeconfig_file="${BOOTSTRAP_DIR}/secrets/cluster/${cluster_id}/kubeconfig/kubeconfig"

  if [[ ! -f "$kubeconfig_file" ]]; then
    log "Kubeconfig not found for cluster ${cluster_id}; skipping Argo CD CLI configuration"
    return 0
  fi

  mkdir -p "$config_dir"

  if [[ -f "$config_file" ]]; then
    log "Argo CD CLI config already exists at ${config_file}"
  else
    admin_password="$(
      KUBECONFIG="$kubeconfig_file" kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null \
        | base64 -d 2>/dev/null || true
    )"

    if [[ -z "$admin_password" ]]; then
      log "Argo CD initial admin password not available; skipping CLI login"
      return 0
    fi

    if /usr/local/bin/argocd login "$argocd_server" \
      --username admin \
      --password "$admin_password" \
      --grpc-web \
      --config "$config_file" >/dev/null 2>&1; then
      login_ok="true"
    else
      argocd_opts="--grpc-web --insecure"
      if /usr/local/bin/argocd login "$argocd_server" \
        --username admin \
        --password "$admin_password" \
        --grpc-web \
        --insecure \
        --config "$config_file" >/dev/null 2>&1; then
        login_ok="true"
      fi
    fi

    if [[ "$login_ok" != "true" ]]; then
      log "Argo CD CLI login failed; skipping CLI configuration"
      return 0
    fi
  fi

  install -d -m 0755 "$(dirname "$profile_file")"
  cat > "$profile_file" <<EOF
export ARGOCD_SERVER="${argocd_server}"
export ARGOCD_OPTS="${argocd_opts}"
EOF
  chmod 0644 "$profile_file"

  log "Configured Argo CD CLI for ${argocd_server}"
}

ensure_talos_cpu_compatibility
ensure_openssl
install_restic
install_talosctl
install_tofu
install_argocd
install_k9s
install_kubectl
install_helm
install_wrappers
verify_versions
configure_argocd_cli

log "Done"
