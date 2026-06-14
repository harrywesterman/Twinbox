#!/usr/bin/env bash
# scripts/manager/install-opkssh-on-host.sh
# Idempotently install opkssh on a remote host via SSH.
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

OPKSSH_VERSION="${OPKSSH_VERSION:-0.14.0}"
OPKSSH_SHA256="${OPKSSH_SHA256:-972719cb6dae736af80100fee0854fdd7289f419fc61b3dcace8409b2f043063}"

usage() {
  cat <<EOF
Usage: $0 --host <HOST> --user <USER> [--ssh-key <KEY_FILE>]

Install or update opkssh on a remote host and configure sshd to use it.
Environment variables:
  OPKSSH_ISSUER_URL   Authentik issuer URL for the opkssh application
  OPKSSH_CLIENT_ID    Authentik client ID for the opkssh application
  OPKSSH_PRINCIPAL    Linux user that Authentik admins may SSH as (default: derived from --user)
  OPKSSH_VERSION      opkssh release version (default: ${OPKSSH_VERSION})
  OPKSSH_SHA256       Expected SHA256 of the binary (default: ${OPKSSH_SHA256})
EOF
}

host=""
user=""
ssh_key_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      host="${2:-}"
      shift 2
      ;;
    --user)
      user="${2:-}"
      shift 2
      ;;
    --ssh-key)
      ssh_key_file="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$host" ]] || fail "--host is required"
[[ -n "$user" ]] || fail "--user is required"
[[ -n "${OPKSSH_ISSUER_URL:-}" ]] || fail "OPKSSH_ISSUER_URL is required"
[[ -n "${OPKSSH_CLIENT_ID:-}" ]] || fail "OPKSSH_CLIENT_ID is required"

principal="${OPKSSH_PRINCIPAL:-$user}"

ssh_args=(
  -o "StrictHostKeyChecking=accept-new"
  -o "UserKnownHostsFile=/dev/null"
  -o "BatchMode=yes"
  -o "ConnectTimeout=10"
)
if [[ -n "$ssh_key_file" ]]; then
  ssh_args+=( -i "$ssh_key_file" )
fi

log "Installing opkssh v${OPKSSH_VERSION} on ${user}@${host}"

ssh "${ssh_args[@]}" "${user}@${host}" bash -s <<REMOTE
set -euo pipefail

OPKSSH_VERSION="${OPKSSH_VERSION}"
OPKSSH_SHA256="${OPKSSH_SHA256}"
ISSUER_URL="${OPKSSH_ISSUER_URL}"
CLIENT_ID="${OPKSSH_CLIENT_ID}"
PRINCIPAL="${principal}"

install_opkssh() {
  echo "Downloading opkssh binary..."
  curl -fsSL "https://github.com/openpubkey/opkssh/releases/download/v\${OPKSSH_VERSION}/opkssh-linux-amd64" -o /tmp/opkssh
  echo "\${OPKSSH_SHA256}  /tmp/opkssh" | sha256sum -c -
  install -o root -g root -m 0755 /tmp/opkssh /usr/local/bin/opkssh
  rm -f /tmp/opkssh
}

if [[ -x /usr/local/bin/opkssh ]]; then
  current_version="\$(/usr/local/bin/opkssh version 2>/dev/null | awk '{print \$NF}' || true)"
  if [[ "\${current_version}" != "v\${OPKSSH_VERSION}" ]]; then
    echo "Upgrading opkssh from \${current_version} to v\${OPKSSH_VERSION}"
    install_opkssh
  else
    echo "opkssh v\${OPKSSH_VERSION} already installed"
  fi
else
  install_opkssh
fi

if ! id -u opksshuser >/dev/null 2>&1; then
  groupadd -r opksshuser || true
  useradd -r -g opksshuser -s /usr/sbin/nologin -d /var/lib/opksshuser -m opksshuser || true
fi

mkdir -p /etc/opk
chown root:opksshuser /etc/opk
chmod 0750 /etc/opk

cat > /etc/opk/providers <<EOF
\${ISSUER_URL} \${CLIENT_ID} 16h
EOF
chown root:opksshuser /etc/opk/providers
chmod 0640 /etc/opk/providers

cat > /etc/opk/auth_id <<EOF
\${PRINCIPAL} oidc:groups:admins \${ISSUER_URL}
EOF
chown root:opksshuser /etc/opk/auth_id
chmod 0640 /etc/opk/auth_id

cat > /etc/ssh/sshd_config.d/60-opk-ssh.conf <<'SSHD'
AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t
AuthorizedKeysCommandUser opksshuser
SSHD
chmod 0644 /etc/ssh/sshd_config.d/60-opk-ssh.conf

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1; then
    systemctl restart sshd || systemctl restart ssh || true
  fi
fi

echo "Verifying opkssh installation..."
/usr/local/bin/opkssh verify --help >/dev/null
/usr/local/bin/opkssh audit
REMOTE

log "opkssh installation complete on ${user}@${host}"
