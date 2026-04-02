#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="twinbox-management-maintenance.service"
TIMER_NAME="twinbox-management-maintenance.timer"

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

install -D -m 0644 "${REPO_ROOT}/systemd/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
install -D -m 0644 "${REPO_ROOT}/systemd/${TIMER_NAME}" "/etc/systemd/system/${TIMER_NAME}"

systemctl daemon-reload
systemctl enable --now "${TIMER_NAME}"

echo "Installed ${SERVICE_NAME} and ${TIMER_NAME}"
echo "The timer will invoke ${REPO_ROOT}/scripts/management-vm-maintenance.sh"

