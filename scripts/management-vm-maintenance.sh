#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
PLAYBOOK="${BOOTSTRAP_DIR}/ansible/management-vm-maintenance.yml"

if [[ ! -f "$PLAYBOOK" ]]; then
  PLAYBOOK="${REPO_ROOT}/ansible/management-vm-maintenance.yml"
fi

log() {
  printf '[management-vm-maintenance] %s\n' "$1"
}

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "${REPO_ROOT}/.env"
  set +a
fi

if [[ -f "${BOOTSTRAP_DIR}/ansible/runtime.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "${BOOTSTRAP_DIR}/ansible/runtime.env"
  set +a
fi

missing_packages=()

if ! command -v ansible-playbook >/dev/null 2>&1; then
  missing_packages+=(ansible-core)
fi

if ! dpkg -s python3-apt >/dev/null 2>&1; then
  missing_packages+=(python3-apt)
fi

if [[ "${#missing_packages[@]}" -gt 0 ]]; then
  log "Installing maintenance prerequisites: ${missing_packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "${missing_packages[@]}" >/dev/null
fi

log "Running management VM maintenance playbook"
exec ansible-playbook -i localhost, -c local "$PLAYBOOK"
