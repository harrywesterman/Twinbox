#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
fail() { echo "ERROR: $*" >&2; exit 1; }

cluster_id="$(jq -r '.cluster.id // empty' <<<"$STEP_CONTEXT_JSON")"
mode="$(jq -r '.crowdsec_mode // "observe"' <<<"$STEP_INPUTS_JSON")"
[[ -n "$cluster_id" ]] || fail "Missing cluster ID"
case "$mode" in observe|enforce) ;; *) fail "Invalid CrowdSec mode" ;; esac

bastion_secret="/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json"
network_secret="/opt/twinbox/bootstrap/secrets/global/netbird-network-${cluster_id}.json"
[[ -f "$bastion_secret" && -f "$network_secret" ]] || fail "NetBird bastion or network secret is missing"
ssh_host="$(jq -r '.BASTION_SSH_HOST // empty' "$bastion_secret")"
ssh_port="$(jq -r '.BASTION_SSH_PORT // "22"' "$bastion_secret")"
ssh_user="$(jq -r '.BASTION_SSH_USER // empty' "$bastion_secret")"
[[ -n "$ssh_host" && "$ssh_port" =~ ^[0-9]+$ && "$ssh_user" == "root" ]] || fail "Invalid bastion SSH details"
[[ -n "$(jq -r '.SSH_PRIVATE_KEY // empty' "$bastion_secret")" ]] || fail "Bastion SSH key is missing"

key_file="$(mktemp "${TMPDIR:-/tmp}/netbird-crowdsec-key-XXXXXX")"
trap 'rm -f "$key_file"' EXIT
jq -r '.SSH_PRIVATE_KEY' "$bastion_secret" >"$key_file"
chmod 600 "$key_file"
ssh_options=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p "$ssh_port" -i "$key_file")

ssh "${ssh_options[@]}" "${ssh_user}@${ssh_host}" 'test -f /opt/netbird/.twinbox-bastion.json && command -v docker && command -v python3' >/dev/null || fail "Bastion SSH or prerequisites unavailable"
scp -q -o StrictHostKeyChecking=accept-new -o BatchMode=yes -P "$ssh_port" -i "$key_file" \
  "$WORKSPACE_ROOT/scripts/manager/configure-netbird-crowdsec.py" \
  "${ssh_user}@${ssh_host}:/root/configure-netbird-crowdsec.py"

echo "Configuring CrowdSec on Twinbox NetBird bastion"
ssh "${ssh_options[@]}" "${ssh_user}@${ssh_host}" \
  'python3 /root/configure-netbird-crowdsec.py && cd /opt/netbird && docker compose config --quiet && docker compose up -d --wait crowdsec && docker compose up -d proxy traefik dashboard netbird-server' \
  || fail "Bastion CrowdSec configuration failed; inspect backup under /opt/netbird/backups"

python3 "$WORKSPACE_ROOT/scripts/manager/reconcile-netbird-crowdsec-services.py" \
  --bastion-secret "$bastion_secret" \
  --network-secret "$network_secret" \
  --mode "$mode"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n --arg mode "$mode" '{status: "succeeded", outputs: {crowdsec_mode: $mode}}' >"$STEP_RESULT_FILE"
fi
