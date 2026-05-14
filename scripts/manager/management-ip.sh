#!/usr/bin/env bash
set -euo pipefail

# Resolve the management VM IPv4 address without relying on BusyBox-only flags.
resolve_management_vm_ip() {
  local management_ip="${MANAGEMENT_VM_IP:-}"

  if [[ -n "$management_ip" ]]; then
    printf '%s\n' "$management_ip"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    if management_ip="$(
      python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    sock.connect(("1.1.1.1", 80))
    print(sock.getsockname()[0])
except OSError:
    pass
finally:
    sock.close()
PY
    )"; then
      :
    else
      management_ip=""
    fi
    if [[ -n "$management_ip" ]]; then
      printf '%s\n' "$management_ip"
      return 0
    fi
  fi

  if command -v ip >/dev/null 2>&1; then
    if management_ip="$(
      ip route get 1.1.1.1 2>/dev/null | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "src" && (i + 1) <= NF) {
              print $(i + 1)
              exit
            }
          }
        }
      '
    )"; then
      :
    else
      management_ip=""
    fi
    if [[ -n "$management_ip" ]]; then
      printf '%s\n' "$management_ip"
      return 0
    fi
  fi

  return 1
}
