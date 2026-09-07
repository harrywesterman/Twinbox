#!/usr/bin/env bash
set -euo pipefail

: "${TWINBOX_CLUSTER_ID:?cluster id required}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
profile="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/cluster/${TWINBOX_CLUSTER_ID}/backup-storage/metadata.json"
[[ "$(jq -r '.mode' "$profile")" == managed-seaweedfs ]] || exit 0
cluster_slug="$(printf '%s' "${TWINBOX_CLUSTER_SLUG:-$TWINBOX_CLUSTER_ID}" | tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g')"
cluster_dns_domain="$(jq -r '.cluster.dns_domain // empty' <<<"${STEP_CONTEXT_JSON:-}")"
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain" 2>/dev/null || true)"
ip="$(jq -er '.vm.ip_address' "$profile")"
key="$(jq -er '.vm.ssh_private_key' "$profile")"
credentials="$(dirname "$profile")/admin.json"
umask 077
if [[ ! -s "$credentials" ]]; then
  password="$(openssl rand -hex 32)"
  jq -n --arg password "$password" '{username:"admin",password:$password}' >"$credentials"
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jq -r '"WEED_ADMIN_USER=" + .username, "WEED_ADMIN_PASSWORD=" + .password' "$credentials" >"$tmp/admin.env"
opts=(-i "$key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
scp "${opts[@]}" "$tmp/admin.env" "twinbox@${ip}:/tmp/twinbox-admin.env" >/dev/null
ssh "${opts[@]}" "twinbox@${ip}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
install -d -m 0700 /opt/twinbox/seaweedfs-admin
install -m 0600 /tmp/twinbox-admin.env /opt/twinbox/seaweedfs-admin/admin.env
rm -f /tmp/twinbox-admin.env
master_address="$(docker inspect seaweedfs --format '{{(index .NetworkSettings.Networks "bridge").IPAddress}}')"
[[ -n "$master_address" ]] || { echo 'SeaweedFS bridge address unavailable' >&2; exit 1; }
image="$(docker inspect seaweedfs --format '{{.Config.Image}}')"
if docker inspect seaweedfs-admin >/dev/null 2>&1 && ! docker inspect seaweedfs-admin --format '{{join .Config.Cmd " "}}' | grep -Fq -- "-master=${master_address}:9333"; then
  docker rm -f seaweedfs-admin >/dev/null
fi
if ! docker inspect seaweedfs-admin >/dev/null 2>&1; then
  docker run -d --name seaweedfs-admin --restart unless-stopped --network bridge \
    -p 127.0.0.1:23646:23646 --env-file /opt/twinbox/seaweedfs-admin/admin.env \
    -v /opt/twinbox/seaweedfs-admin/data:/data "$image" admin "-master=${master_address}:9333" -dataDir=/data >/dev/null
else
  docker start seaweedfs-admin >/dev/null
fi
cat >/etc/nginx/conf.d/twinbox-admin.conf <<'NGINX'
server {
  listen 8443 ssl;
  ssl_certificate /etc/nginx/twinbox-server.crt;
  ssl_certificate_key /etc/nginx/twinbox-server.key;
  location / {
    proxy_pass http://127.0.0.1:23646;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Proto https;
  }
}
NGINX
nginx -t
systemctl reload nginx
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:23646/ >/dev/null; then exit 0; fi
  sleep 2
done
exit 1
REMOTE
if [[ -n "$public_zone_name" ]]; then
  jq --arg url "https://backup-s3.${public_zone_name}" '.admin = {url:$url}' "$profile" >"$tmp/profile.json"
  mv "$tmp/profile.json" "$profile"
else
  jq --arg url "https://${ip}:8443" '.admin = {url:$url}' "$profile" >"$tmp/profile.json"
  mv "$tmp/profile.json" "$profile"
fi
echo 'SeaweedFS admin configured; login credentials saved beside the backup profile in admin.json'
if [[ -n "$public_zone_name" ]]; then
  BACKUP_S3_PROFILE="$profile" TWINBOX_CLUSTER_SLUG="$cluster_slug" \
    bash "$WORKSPACE_ROOT/scripts/manager/configure-backup-s3-publication.sh"
fi
