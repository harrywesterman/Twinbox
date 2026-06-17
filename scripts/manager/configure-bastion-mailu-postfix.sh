#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: configure-bastion-mailu-postfix.sh \
  --bastion-ip IP \
  --ssh-key-file PATH \
  --mail-domain DOMAIN \
  --mail-hostname HOSTNAME \
  --mailu-front-address ADDRESS \
  [--mailu-front-port 25] \
  --relay-listen-address ADDRESS \
  [--relay-listen-port 2525] \
  --relay-username USERNAME \
  --relay-secret-file PATH \
  --cluster-id ID
USAGE
  exit 1
}

BASTION_IP=""
SSH_KEY_FILE=""
MAIL_DOMAIN=""
MAIL_HOSTNAME=""
MAILU_FRONT_ADDRESS=""
MAILU_FRONT_PORT="25"
RELAY_LISTEN_ADDRESS=""
RELAY_LISTEN_PORT="2525"
RELAY_USERNAME=""
RELAY_SECRET_FILE=""
CLUSTER_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bastion-ip) BASTION_IP="$2"; shift 2 ;;
    --ssh-key-file) SSH_KEY_FILE="$2"; shift 2 ;;
    --mail-domain) MAIL_DOMAIN="$2"; shift 2 ;;
    --mail-hostname) MAIL_HOSTNAME="$2"; shift 2 ;;
    --mailu-front-address) MAILU_FRONT_ADDRESS="$2"; shift 2 ;;
    --mailu-front-port) MAILU_FRONT_PORT="$2"; shift 2 ;;
    --relay-listen-address) RELAY_LISTEN_ADDRESS="$2"; shift 2 ;;
    --relay-listen-port) RELAY_LISTEN_PORT="$2"; shift 2 ;;
    --relay-username) RELAY_USERNAME="$2"; shift 2 ;;
    --relay-secret-file) RELAY_SECRET_FILE="$2"; shift 2 ;;
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$BASTION_IP" ]] || usage
[[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]] || usage
[[ -n "$MAIL_DOMAIN" ]] || usage
[[ -n "$MAIL_HOSTNAME" ]] || usage
[[ -n "$MAILU_FRONT_ADDRESS" ]] || usage
[[ -n "$MAILU_FRONT_PORT" ]] || usage
[[ -n "$RELAY_LISTEN_ADDRESS" ]] || usage
[[ -n "$RELAY_LISTEN_PORT" ]] || usage
[[ -n "$RELAY_USERNAME" ]] || usage
[[ -n "$RELAY_SECRET_FILE" && -f "$RELAY_SECRET_FILE" ]] || usage
[[ -n "$CLUSTER_ID" ]] || usage

case "$MAIL_DOMAIN" in
  *[!A-Za-z0-9.-]*|.*|*.) echo "Invalid mail domain: $MAIL_DOMAIN" >&2; exit 1 ;;
esac
case "$MAIL_HOSTNAME" in
  *[!A-Za-z0-9.-]*|.*|*.) echo "Invalid mail hostname: $MAIL_HOSTNAME" >&2; exit 1 ;;
esac
case "$MAILU_FRONT_PORT:$RELAY_LISTEN_PORT" in
  *[!0-9:]*|:*) echo "Invalid port" >&2; exit 1 ;;
esac
case "$RELAY_LISTEN_ADDRESS" in
  0.0.0.0|"$BASTION_IP") echo "Refusing to expose relay listener on public address: $RELAY_LISTEN_ADDRESS" >&2; exit 1 ;;
esac

quote() {
  printf '%q' "$1"
}

command -v jq >/dev/null 2>&1 || {
  echo "jq not found" >&2
  exit 1
}

ssh_opts=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -i "$SSH_KEY_FILE"
)

remote_env=(
  "MAIL_DOMAIN=$(quote "$MAIL_DOMAIN")"
  "MAIL_HOSTNAME=$(quote "$MAIL_HOSTNAME")"
  "MAILU_FRONT_ADDRESS=$(quote "$MAILU_FRONT_ADDRESS")"
  "MAILU_FRONT_PORT=$(quote "$MAILU_FRONT_PORT")"
  "RELAY_LISTEN_ADDRESS=$(quote "$RELAY_LISTEN_ADDRESS")"
  "RELAY_LISTEN_PORT=$(quote "$RELAY_LISTEN_PORT")"
  "RELAY_USERNAME=$(quote "$RELAY_USERNAME")"
  "RELAY_PASSWORD_FILE=$(quote "/etc/postfix/twinbox-mailu/relay-password-${CLUSTER_ID}")"
  "CLUSTER_ID=$(quote "$CLUSTER_ID")"
)

remote_relay_password_file="/etc/postfix/twinbox-mailu/relay-password-${CLUSTER_ID}"
remote_secret_uploaded=0
cleanup_remote_secret() {
  if [[ "$remote_secret_uploaded" == "1" ]]; then
    ssh "${ssh_opts[@]}" "root@${BASTION_IP}" "rm -f $(quote "$remote_relay_password_file")" >/dev/null 2>&1 || true
  fi
}
trap cleanup_remote_secret EXIT

relay_password="$(jq -r '."relay-password" // empty' "$RELAY_SECRET_FILE")"
[[ -n "$relay_password" ]] || {
  echo "Relay secret file is missing relay-password" >&2
  exit 1
}
printf '%s' "$relay_password" | ssh "${ssh_opts[@]}" "root@${BASTION_IP}" "install -d -m 0750 /etc/postfix/twinbox-mailu && umask 077 && cat > $(quote "$remote_relay_password_file")"
remote_secret_uploaded=1
unset relay_password

ssh "${ssh_opts[@]}" "root@${BASTION_IP}" "${remote_env[*]} bash -s" <<'REMOTE'
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
trap 'rm -f "$RELAY_PASSWORD_FILE"' EXIT
echo "postfix postfix/main_mailer_type string Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_HOSTNAME}" | debconf-set-selections
apt-get update -y >/dev/null
apt-get install -y postfix libsasl2-modules sasl2-bin ca-certificates ssl-cert swaks >/dev/null

install -d -m 0750 /etc/postfix/twinbox-mailu
install -d -m 0755 /etc/postfix/sasl

cat >/etc/postfix/twinbox-mailu/relay_domains <<EOF
# Managed by Twinbox Mail. Do not edit by hand.
${MAIL_DOMAIN} OK
EOF

cat >/etc/postfix/twinbox-mailu/transport <<EOF
# Managed by Twinbox Mail. Do not edit by hand.
${MAIL_DOMAIN} smtp:[${MAILU_FRONT_ADDRESS}]:${MAILU_FRONT_PORT}
EOF

postmap /etc/postfix/twinbox-mailu/relay_domains
postmap /etc/postfix/twinbox-mailu/transport

cat >/etc/postfix/sasl/smtpd.conf <<'EOF'
# Managed by Twinbox Mail. Do not edit by hand.
pwcheck_method: auxprop
auxprop_plugin: sasldb
sasldb_path: /etc/sasldb2
mech_list: PLAIN LOGIN
EOF

relay_password="$(cat "$RELAY_PASSWORD_FILE")"
printf '%s\n' "$relay_password" | saslpasswd2 -c -p -u "$MAIL_HOSTNAME" "$RELAY_USERNAME"
unset relay_password
if [[ -f /etc/sasldb2 ]]; then
  chgrp postfix /etc/sasldb2 || true
  chmod 0640 /etc/sasldb2 || true
fi

relay_interface="$(ip -o -4 addr show | awk -v ip="$RELAY_LISTEN_ADDRESS" '{split($4,a,"/"); if (a[1] == ip) {print $2; exit}}')"
[[ -n "$relay_interface" ]] || fail "Relay listen address ${RELAY_LISTEN_ADDRESS} is not configured on the bastion"

postconf -e "myhostname = bastion.${MAIL_DOMAIN}"
postconf -e "myorigin = ${MAIL_DOMAIN}"
postconf -e "smtpd_sasl_local_domain = ${MAIL_HOSTNAME}"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "relay_domains = hash:/etc/postfix/twinbox-mailu/relay_domains"
postconf -e "transport_maps = hash:/etc/postfix/twinbox-mailu/transport"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination"
postconf -e "smtpd_sasl_auth_enable = no"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem && -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
  postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem"
  postconf -e "smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key"
fi
postconf -e "disable_vrfy_command = yes"

awk '
  $0 == "# BEGIN Twinbox Mail relay listener" {skip=1; next}
  $0 == "# END Twinbox Mail relay listener" {skip=0; next}
  skip != 1 {print}
' /etc/postfix/master.cf > /etc/postfix/master.cf.twinbox
cat /etc/postfix/master.cf.twinbox > /etc/postfix/master.cf
rm -f /etc/postfix/master.cf.twinbox

cat >>/etc/postfix/master.cf <<EOF

# BEGIN Twinbox Mail relay listener
# Managed by Twinbox Mail. Do not edit by hand.
${RELAY_LISTEN_ADDRESS}:${RELAY_LISTEN_PORT} inet n       -       -       -       -       smtpd
  -o syslog_name=postfix/twinbox-mailu-relay
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=cyrus
  -o smtpd_sasl_path=smtpd
  -o smtpd_tls_security_level=encrypt
  -o smtpd_tls_auth_only=yes
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
# END Twinbox Mail relay listener
EOF

if postconf -h mynetworks | grep -Eq '(^|[[:space:],])0\.0\.0\.0/0([[:space:],]|$)'; then
  fail "Refusing to reload Postfix with public mynetworks"
fi
if postconf -h smtpd_relay_restrictions | grep -Eq 'permit($|[[:space:],])'; then
  fail "Refusing to reload Postfix with unconditional relay permit"
fi

postfix check
systemctl enable postfix >/dev/null
systemctl restart postfix

ufw allow 25/tcp >/dev/null || true
ufw allow in on "$relay_interface" to "$RELAY_LISTEN_ADDRESS" port "$RELAY_LISTEN_PORT" proto tcp >/dev/null || true
ufw deny in to any port "$RELAY_LISTEN_PORT" proto tcp >/dev/null || true
ufw reload >/dev/null || true

if ss -ltn | awk '{print $4}' | grep -Eq '(^|:)0\.0\.0\.0:'"${RELAY_LISTEN_PORT}"'$'; then
  fail "Relay listener is public on 0.0.0.0:${RELAY_LISTEN_PORT}"
fi

log "Twinbox Mail Postfix edge configured for ${MAIL_DOMAIN} via ${MAILU_FRONT_ADDRESS}:${MAILU_FRONT_PORT}"
REMOTE
