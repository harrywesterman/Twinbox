#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
if [[ -f "$WORKSPACE_ROOT/config/pinned-defaults.sh" ]]; then
  # shellcheck disable=SC1091
  source "$WORKSPACE_ROOT/config/pinned-defaults.sh"
fi

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

wait_for_argocd_server() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD server"
  for i in $(seq 1 30); do
    ready="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    if [[ "${ready:-0}" -gt 0 ]]; then
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done
  fail "Argo CD server did not become ready"
}

wait_for_netbird_routing_peer() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird routing peer deployment"
  for i in $(seq 1 60); do
    if kubectl -n netbird get deployment netbird-routing-peer >/dev/null 2>&1; then
      kubectl -n netbird rollout status deployment/netbird-routing-peer --timeout=180s
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird routing peer deployment not ready yet (attempt ${i}/60)"
    sleep 5
  done
  fail "NetBird routing peer deployment did not appear"
}

wait_for_traefik_reverse_proxy_backend() {
  local address="$1"
  local service_name="traefik"
  local label_selector="kubernetes.io/service-name=traefik"
  local description="Traefik websecure"

  if [[ "$address" == "traefik-netbird.traefik.svc.cluster.local" ]]; then
    service_name="traefik-netbird"
    label_selector="kubernetes.io/service-name=traefik-netbird"
    description="Traefik NetBird"
  elif [[ "$address" != "traefik.traefik.svc.cluster.local" ]]; then
    return 0
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for ${description} backend endpoints"
  for i in $(seq 1 30); do
    if kubectl -n traefik get endpointslice -l "$label_selector" -o json 2>/dev/null \
      | jq -e '([.items[].endpoints[]? | select(.conditions.ready != false)] | length) > 0' >/dev/null; then
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${description} backend endpoints not ready yet (attempt ${i}/30)"
    sleep 5
  done
  fail "${description} backend service ${service_name} did not become ready"
}

resolve_traefik_websecure_endpoint() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Resolving Traefik websecure pod endpoint for NetBird proxy" >&2
  for i in $(seq 1 30); do
    endpoint="$(
      kubectl -n traefik get endpointslice -l kubernetes.io/service-name=traefik -o json 2>/dev/null \
        | jq -r '[.items[].endpoints[]? | select(.conditions.ready != false) | .addresses[]?][0] // empty'
    )"
    if [[ -n "$endpoint" ]]; then
      printf '%s\n' "$endpoint"
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Traefik websecure pod endpoint not ready yet (attempt ${i}/30)" >&2
    sleep 5
  done
  fail "Traefik websecure pod endpoint did not become ready"
}

read_pod_cidrs_json() {
  local cidrs_json
  cidrs_json="$(
    kubectl get nodes -o json 2>/dev/null \
      | jq -c '[.items[] | (.spec.podCIDRs[]? // .spec.podCIDR?)] | map(select(. != null and . != "")) | unique' \
      || true
  )"
  if [[ -z "$cidrs_json" || "$cidrs_json" == "[]" || "$cidrs_json" == "null" ]]; then
    cidrs_json='["10.244.0.0/16"]'
  fi
  printf '%s\n' "$cidrs_json"
}

wait_for_public_oidc_discovery() {
  local issuer_url="$1"
  local discovery_url="${issuer_url%/}/.well-known/openid-configuration"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for public Authentik OIDC discovery through NetBird proxy"
  for i in $(seq 1 60); do
    if curl -fsS --connect-timeout 5 --max-time 15 "$discovery_url" >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public Authentik OIDC discovery is reachable"
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public Authentik OIDC discovery not reachable yet (attempt ${i}/60): ${discovery_url}"
    sleep 5
  done
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Public Authentik OIDC discovery is not reachable through NetBird proxy yet: ${discovery_url}" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Continuing NetBird configuration; browser SSO will be healthy once public TLS and proxy reachability are ready." >&2
  return 0
}

verify_public_oidc_authorize() {
  local authentik_base_url="$1"
  local client_id="$2"
  local redirect_uri="$3"
  local authorize_url="${authentik_base_url%/}/application/o/authorize/"
  local response_headers
  local http_code
  local location
  local state
  local code_verifier
  local code_challenge

  state="$(openssl rand -hex 16)"
  code_verifier="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  code_challenge="$(python3 - "$code_verifier" <<'PY'
import base64
import hashlib
import sys

verifier = sys.argv[1].encode()
challenge = hashlib.sha256(verifier).digest()
print(base64.urlsafe_b64encode(challenge).decode().rstrip("="))
PY
)"

  response_headers="$(
    curl -sS -o /dev/null -D - \
      --connect-timeout 5 \
      --max-time 15 \
      --get \
      --data-urlencode "client_id=${client_id}" \
      --data-urlencode "code_challenge=${code_challenge}" \
      --data-urlencode "code_challenge_method=S256" \
      --data-urlencode "redirect_uri=${redirect_uri}" \
      --data-urlencode "response_type=code" \
      --data-urlencode "scope=openid profile email" \
      --data-urlencode "state=${state}" \
      "$authorize_url"
  )"

  http_code="$(sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' <<<"$response_headers" | tail -n1)"
  location="$(sed -n 's/^location: //p' <<<"$response_headers" | tail -n1)"

  if [[ "$http_code" != "302" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Authentik authorize endpoint did not return a redirect for NetBird" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: URL=${authorize_url} client_id=${client_id}" >&2
    echo "$response_headers" >&2
    return 1
  fi

  if [[ -z "$location" || "$location" != /if/flow/* ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Authentik authorize endpoint returned an unexpected Location header" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: location=${location:-<empty>}" >&2
    echo "$response_headers" >&2
    return 1
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public Authentik authorize endpoint is reachable and redirects into the login flow"
}

wait_for_public_oidc_authorize() {
  local authentik_base_url="$1"
  local client_id="$2"
  local redirect_uri="$3"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for public Authentik authorize endpoint through NetBird proxy"
  for i in $(seq 1 30); do
    if verify_public_oidc_authorize "$authentik_base_url" "$client_id" "$redirect_uri"; then
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public Authentik authorize endpoint not ready yet (attempt ${i}/30)"
    sleep 5
  done

  fail "Public Authentik authorize endpoint did not become reachable through NetBird proxy"
}

netbird_host_resource_address() {
  local address="$1"
  if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s/32' "$address"
    return
  fi
  printf '%s' "$address"
}

ensure_netbird_proxy_peer() {
  local setup_key="$1"
  local ssh_key_path="$MANAGER_DATA_DIR/ssh/netbird-${cluster_id}/id_ed25519"
  local temp_ssh_key=""
  local image="netbirdio/netbird:${PINNED_NETBIRD_VERSION:-0.70.5}"
  local hostname="twinbox-${cluster_id}-proxy"
  local management_url_q
  local hostname_q
  local image_q

  if [[ ! -f "$ssh_key_path" ]]; then
    if jq -e '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret" >/dev/null; then
      temp_ssh_key="$(mktemp)"
      jq -r '.SSH_PRIVATE_KEY' "$netbird_bastion_secret" >"$temp_ssh_key"
      chmod 600 "$temp_ssh_key"
      ssh_key_path="$temp_ssh_key"
    fi
  fi

  if [[ ! -f "$ssh_key_path" || -z "$netbird_proxy_ip" ]] || ! command -v ssh >/dev/null 2>&1; then
    [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
    fail "NetBird bastion SSH is unavailable; cannot start the reverse proxy peer"
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ensuring NetBird reverse proxy peer is running on the bastion"
  if ! printf '%s' "$setup_key" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 \
    -i "$ssh_key_path" root@"$netbird_proxy_ip" \
    'mkdir -p /opt/netbird && umask 077 && cat > /opt/netbird/proxy-client.setup-key'; then
    [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
    fail "Failed to upload NetBird proxy setup key to the bastion"
  fi

  printf -v management_url_q '%q' "$netbird_management_url"
  printf -v hostname_q '%q' "$hostname"
  printf -v image_q '%q' "$image"

  if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 \
    -i "$ssh_key_path" root@"$netbird_proxy_ip" \
    "NB_MANAGEMENT_URL=$management_url_q NB_HOSTNAME=$hostname_q NETBIRD_IMAGE=$image_q bash -s" <<'REMOTE'
set -euo pipefail

setup_key="$(cat /opt/netbird/proxy-client.setup-key)"
modprobe tun 2>/dev/null || true
mkdir -p /var/lib/netbird-proxy-client /opt/netbird
cat > /opt/netbird/proxy-client.env <<EOF
NB_SETUP_KEY=${setup_key}
NB_MANAGEMENT_URL=${NB_MANAGEMENT_URL}
NB_HOSTNAME=${NB_HOSTNAME}
NB_LOG_LEVEL=info
EOF
chmod 600 /opt/netbird/proxy-client.env

docker pull "$NETBIRD_IMAGE" >/dev/null
docker rm -f netbird-client >/dev/null 2>&1 || true
docker run -d \
  --name netbird-client \
  --restart unless-stopped \
  --network host \
  --privileged \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  --cap-add SYS_RESOURCE \
  --device /dev/net/tun \
  --env-file /opt/netbird/proxy-client.env \
  -v /var/lib/netbird-proxy-client:/var/lib/netbird \
  "$NETBIRD_IMAGE" >/dev/null

for i in $(seq 1 30); do
  if docker exec netbird-client netbird status --check ready >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done

docker logs --tail 80 netbird-client >&2 || true
exit 1
REMOTE
  then
    [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
    fail "Failed to start NetBird reverse proxy peer on the bastion"
  fi

  [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
}

wait_for_netbird_proxy_backend() {
  local ssh_key_path="$MANAGER_DATA_DIR/ssh/netbird-${cluster_id}/id_ed25519"
  local temp_ssh_key=""
  local endpoint="$1"
  local port="$2"
  local host_header="$3"
  local path="$4"
  local url="https://${endpoint}:${port}${path}"
  local url_q
  local host_header_q

  if [[ ! -f "$ssh_key_path" ]]; then
    if jq -e '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret" >/dev/null; then
      temp_ssh_key="$(mktemp)"
      jq -r '.SSH_PRIVATE_KEY' "$netbird_bastion_secret" >"$temp_ssh_key"
      chmod 600 "$temp_ssh_key"
      ssh_key_path="$temp_ssh_key"
    fi
  fi

  [[ -f "$ssh_key_path" ]] || fail "NetBird bastion SSH key is unavailable; cannot verify reverse proxy backend"
  printf -v url_q '%q' "$url"
  printf -v host_header_q '%q' "$host_header"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NetBird proxy peer to reach Traefik websecure"
  for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 \
      -i "$ssh_key_path" root@"$netbird_proxy_ip" \
      "curl -kfsS --connect-timeout 5 --max-time 10 -H Host:$host_header_q $url_q >/dev/null"; then
      [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NetBird proxy peer cannot reach Traefik websecure yet (attempt ${i}/60)"
    sleep 5
  done

  [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
  fail "NetBird proxy peer could not reach Traefik websecure"
}

read_first_admin_email() {
  local cluster_scope="$1"
  local state_file
  local email
  local candidate_paths=(
    "$MANAGER_DATA_DIR/step-state/clusters/${cluster_scope}/create-users-and-groups.json"
    "$MANAGER_DATA_DIR/step-state/clusters/${cluster_id}/create-users-and-groups.json"
    "$MANAGER_DATA_DIR/step-state/global/create-users-and-groups.json"
  )

  for state_file in "${candidate_paths[@]}"; do
    [[ -f "$state_file" ]] || continue
    email="$(jq -r '.inputs.email // .outputs.email // empty' "$state_file")"
    if [[ -n "$email" ]]; then
      printf '%s\n' "$email"
      return 0
    fi
  done

  return 1
}

authentik_user_uid_by_email() {
  local email="$1"
  local encoded_email
  local response

  encoded_email="$(jq -rn --arg value "$email" '$value | @uri')"
  response="$(authentik_api_get "/core/users/?search=${encoded_email}&page_size=100")"
  printf '%s' "$response" | jq -r --arg email "$email" '
    (.results // [])
    | map(select((.email // "" | ascii_downcase) == ($email | ascii_downcase)))
    | .[0].uid // empty
  '
}

seed_netbird_account_for_sso() {
  local identity_provider_id="$1"
  local admin_email="$2"
  local admin_uid=""
  local ssh_key_path="$MANAGER_DATA_DIR/ssh/netbird-${cluster_id}/id_ed25519"
  local temp_ssh_key=""
  local public_zone_q
  local cluster_id_q
  local admin_uid_q
  local identity_provider_id_q
  local admin_email_q

  if [[ -n "$admin_email" ]]; then
    admin_uid="$(authentik_user_uid_by_email "$admin_email")"
    if [[ -z "$admin_uid" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Could not resolve Authentik user uid for ${admin_email}; NetBird SSO owner preseed skipped." >&2
    fi
  fi

  if [[ ! -f "$ssh_key_path" ]]; then
    if jq -e '.SSH_PRIVATE_KEY // empty' "$netbird_bastion_secret" >/dev/null; then
      temp_ssh_key="$(mktemp)"
      jq -r '.SSH_PRIVATE_KEY' "$netbird_bastion_secret" >"$temp_ssh_key"
      chmod 600 "$temp_ssh_key"
      ssh_key_path="$temp_ssh_key"
    fi
  fi

  if [[ ! -f "$ssh_key_path" || -z "$netbird_proxy_ip" ]] || ! command -v ssh >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: NetBird host SSH is unavailable; account domain and SSO owner preseed skipped." >&2
    [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
    return 0
  fi

  printf -v public_zone_q '%q' "$public_zone_name"
  printf -v cluster_id_q '%q' "$cluster_id"
  printf -v admin_uid_q '%q' "$admin_uid"
  printf -v identity_provider_id_q '%q' "$identity_provider_id"
  printf -v admin_email_q '%q' "$admin_email"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Seeding NetBird account domain and SSO owner context"
  if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 \
    -i "$ssh_key_path" root@"$netbird_proxy_ip" \
    "PUBLIC_ZONE_NAME=$public_zone_q CLUSTER_ID=$cluster_id_q ADMIN_UID=$admin_uid_q CONNECTOR_ID=$identity_provider_id_q ADMIN_EMAIL=$admin_email_q python3 -" <<'PY'
import base64
import glob
import json
import os
import shutil
import sqlite3
import time

public_zone_name = os.environ["PUBLIC_ZONE_NAME"]
cluster_id = os.environ["CLUSTER_ID"]
admin_uid = os.environ.get("ADMIN_UID", "")
connector_id = os.environ.get("CONNECTOR_ID", "")
admin_email = os.environ.get("ADMIN_EMAIL", "")
store_db_candidates = [
    "/var/lib/docker/volumes/netbird_netbird_data/_data/store.db",
    "/var/lib/docker/volumes/netbird-server_netbird_data/_data/store.db",
    "/var/lib/docker/volumes/netbird_netbird-data/_data/store.db",
]
store_db = next((path for path in store_db_candidates if os.path.exists(path)), "")
if not store_db:
    store_db = next(
        (
            path
            for path in glob.glob("/var/lib/docker/volumes/*/_data/store.db")
            if "netbird" in path
        ),
        "",
    )

if not os.path.exists(store_db):
    print("WARNING: NetBird store database not found; cannot seed SSO account context.")
    raise SystemExit(0)

backup_dir = "/opt/netbird/twinbox-db-backups"
os.makedirs(backup_dir, exist_ok=True)
stamp = time.strftime("%Y%m%d%H%M%S")
shutil.copy2(store_db, os.path.join(backup_dir, f"store.db.{stamp}.bak"))

def encode_dex_user_id(user_id, provider_id):
    if len(user_id) > 255 or len(provider_id) > 255:
        raise ValueError("Dex user ID components are too long")
    raw = (
        bytes([0x0A, len(user_id)])
        + user_id.encode()
        + bytes([0x12, len(provider_id)])
        + provider_id.encode()
    )
    return base64.b64encode(raw).decode().rstrip("=")

with sqlite3.connect(store_db) as connection:
    connection.row_factory = sqlite3.Row
    connection.execute("begin immediate")

    admin_group_name = f"twinbox-{cluster_id}-admins"
    admin_group = connection.execute(
        "select id, account_id from groups where name = ? order by id limit 1",
        (admin_group_name,),
    ).fetchone()
    if admin_group is None:
        account = connection.execute(
            "select id from accounts order by created_at limit 1",
        ).fetchone()
        if account is None:
            print("WARNING: NetBird account not found; cannot seed SSO account context.")
            connection.rollback()
            raise SystemExit(0)
        target_account_id = account["id"]
        admin_group_id = ""
    else:
        target_account_id = admin_group["account_id"]
        admin_group_id = admin_group["id"]

    connection.execute(
        "update accounts set domain = ?, domain_category = ?, is_domain_primary_account = 1, "
        "settings_extra_user_approval_required = 0 where id = ?",
        (public_zone_name, "private", target_account_id),
    )
    connection.execute(
        "update account_onboardings set onboarding_flow_pending = 0 where account_id = ?",
        (target_account_id,),
    )

    deleted_accounts = []
    if admin_uid and connector_id:
        sso_user_id = encode_dex_user_id(admin_uid, connector_id)
        padded_sso_user_id = base64.b64encode(
            bytes([0x0A, len(admin_uid)])
            + admin_uid.encode()
            + bytes([0x12, len(connector_id)])
            + connector_id.encode()
        ).decode()
        auto_groups = json.dumps([admin_group_id] if admin_group_id else [])

        connection.execute(
            "delete from users where id = ? and account_id = ?",
            (padded_sso_user_id, target_account_id),
        )
        existing = connection.execute(
            "select id from users where id = ?",
            (sso_user_id,),
        ).fetchone()
        if existing:
            connection.execute(
                "update users set account_id = ?, role = ?, blocked = 0, pending_approval = 0, auto_groups = ? where id = ?",
                (target_account_id, "owner", auto_groups, sso_user_id),
            )
        else:
            connection.execute(
                "insert into users (id, account_id, role, is_service_user, non_deletable, service_user_name, "
                "auto_groups, blocked, pending_approval, last_login, created_at, issued, integration_ref_id, "
                "integration_ref_integration_type, name, email) "
                "values (?, ?, ?, 0, 0, ?, ?, 0, 0, NULL, datetime('now'), ?, 0, ?, ?, ?)",
                (sso_user_id, target_account_id, "owner", "", auto_groups, "api", "", "", ""),
            )

        duplicate_accounts = [
            row["id"]
            for row in connection.execute(
                "select id from accounts where id != ? and created_by in (?, ?)",
                (target_account_id, sso_user_id, padded_sso_user_id),
            )
        ]
        for account_id in duplicate_accounts:
            remaining_users = connection.execute(
                "select count(*) from users where account_id = ? and id not in (?, ?)",
                (account_id, sso_user_id, padded_sso_user_id),
            ).fetchone()[0]
            if remaining_users:
                continue

            policies = [
                row["id"]
                for row in connection.execute(
                    "select id from policies where account_id = ?",
                    (account_id,),
                )
            ]
            if policies:
                connection.executemany(
                    "delete from policy_rules where policy_id = ?",
                    [(policy_id,) for policy_id in policies],
                )

            for table in [
                "account_onboardings",
                "group_peers",
                "groups",
                "policies",
                "routes",
                "networks",
                "network_routers",
                "network_resources",
                "setup_keys",
                "peers",
                "services",
                "targets",
                "domains",
                "zones",
                "records",
                "name_server_groups",
                "posture_checks",
                "proxy_access_tokens",
                "access_log_entries",
                "jobs",
                "user_invites",
            ]:
                try:
                    connection.execute(f"delete from {table} where account_id = ?", (account_id,))
                except sqlite3.OperationalError:
                    pass
            connection.execute("delete from users where account_id = ?", (account_id,))
            connection.execute("delete from accounts where id = ?", (account_id,))
            deleted_accounts.append(account_id)

    connection.commit()

    print(
        json.dumps(
            {
                "target_account": target_account_id,
                "domain": public_zone_name,
                "admin_email": admin_email,
                "sso_owner_seeded": bool(admin_uid and connector_id),
                "deleted_duplicate_accounts": deleted_accounts,
            },
            sort_keys=True,
        )
    )
PY
  then
    [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
    fail "Failed to seed NetBird account domain and SSO owner context"
  fi

  [[ -z "$temp_ssh_key" ]] || rm -f "$temp_ssh_key"
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_scope_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "${cluster_dns_domain:-}")"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

netbird_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_token // empty')"
netbird_management_url="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_management_url // empty')"
netbird_admin_email="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.netbird_admin_email // empty')"
traefik_resource_address="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.traefik_resource_address // empty')"
proxy_services_json="$(printf '%s' "$STEP_INPUTS_JSON" | jq -c '.proxy_services_json // empty')"
if [[ -n "$proxy_services_json" && "$proxy_services_json" != "null" ]]; then
  proxy_services_json="$(printf '%s' "$proxy_services_json" | jq -r '.')"
fi

if [[ -z "$netbird_admin_email" ]]; then
  netbird_admin_email="$(read_first_admin_email "$cluster_scope_id" || true)"
fi

netbird_bastion_secret="/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json"
if [[ -z "$netbird_management_url" ]]; then
  [[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at $netbird_bastion_secret"
  netbird_management_url="$(jq -r '.NETBIRD_URL // empty' "$netbird_bastion_secret")"
fi

if [[ -z "$netbird_token" ]]; then
  if [[ -f "$netbird_bastion_secret" ]]; then
    netbird_token="$(jq -r '.NETBIRD_SETUP_TOKEN // empty' "$netbird_bastion_secret")"
  fi
fi

[[ -n "$netbird_token" ]] || fail "NetBird API token is required. Either provide it as input or ensure the bastion step generated a setup token."
[[ -n "$netbird_management_url" ]] || fail "Could not determine NetBird management URL"
[[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at $netbird_bastion_secret"
netbird_proxy_domain="$(jq -r '.NETBIRD_PROXY_DOMAIN // empty' "$netbird_bastion_secret")"
netbird_proxy_ip="$(jq -r '.NETBIRD_IP // empty' "$netbird_bastion_secret")"

# NETBIRD_PROXY_DOMAIN is now the zone itself (not proxy.<zone>).
# Derive it from NETBIRD_FQDN when the bastion secret doesn't contain it.
if [[ -z "$netbird_proxy_domain" ]]; then
  netbird_proxy_domain="$(jq -r '.NETBIRD_FQDN // empty' "$netbird_bastion_secret" | sed 's/^netbird\.//')"
fi

[[ -n "$netbird_proxy_ip" ]] || fail "NetBird bastion secret does not contain NETBIRD_IP"

if [[ -z "$traefik_resource_address" ]]; then
  traefik_resource_address="$(resolve_traefik_websecure_endpoint)"
fi
traefik_network_resource_address="$(netbird_host_resource_address "$traefik_resource_address")"
traefik_target_port="8443"

service_cidr="$(kubectl -n kube-system get pod -l component=kube-apiserver -o json 2>/dev/null | jq -r '.items[0].spec.containers[0].command[] | select(startswith("--service-cluster-ip-range=")) | sub("^--service-cluster-ip-range="; "")' || true)"
if [[ -z "$service_cidr" ]]; then
  service_cidr="10.96.0.0/12"
fi
service_cidrs_json="$(jq -n --arg cidr "$service_cidr" '[$cidr]')"
pod_cidrs_json="$(read_pod_cidrs_json)"

authentik_public_url="${TWINBOX_AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
authentik_domain="${authentik_public_url#https://}"
authentik_domain="${authentik_domain#http://}"
authentik_domain="${authentik_domain%%/*}"

if [[ -n "$proxy_services_json" && "$proxy_services_json" != "null" ]]; then
  if ! printf '%s' "$proxy_services_json" | jq -e 'type == "array"' >/dev/null; then
    fail "proxy_services_json must be a JSON array"
  fi
else
  proxy_services_json="[]"
fi
proxy_services_json="$(
  jq -cn \
    --arg authentik_domain "$authentik_domain" \
    --argjson extra "$proxy_services_json" \
    '[{name: "authentik", domain: $authentik_domain, path: "/"}] + ($extra | map(select(.name != "authentik")))'
)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring Authentik OIDC application for NetBird"
authentik_ensure_token
authentik_setup_forward
export AUTHENTIK_TOKEN
authentik_api_url="${AUTHENTIK_API_BASE%/api/v3}"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"

[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

auth_workdir="$MANAGER_DATA_DIR/opentofu/authentik-netbird-${cluster_id}"
mkdir -p "$auth_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-netbird/"* "$auth_workdir/"
cd "$auth_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "authentik_api_url=$authentik_api_url" \
  -var "authentik_public_url=$authentik_public_url" \
  -var "netbird_url=$netbird_management_url" \
  -var "property_mapping_ids=$property_mapping_ids_json"

netbird_oidc_client_id="$(tofu output -raw -no-color client_id)"
netbird_oidc_client_secret="$(tofu output -raw -no-color client_secret)"
netbird_oidc_issuer="$(tofu output -raw -no-color issuer_url)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird groups, routing resources, and setup keys"
network_workdir="$MANAGER_DATA_DIR/opentofu/netbird-network-${cluster_id}"
mkdir -p "$network_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird-network/"* "$network_workdir/"
cd "$network_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "netbird_token=$netbird_token" \
  -var "netbird_management_url=$netbird_management_url" \
  -var "cluster_id=$cluster_id" \
  -var "traefik_resource_address=$traefik_network_resource_address" \
  -var "service_cidrs=${service_cidrs_json}" \
  -var "pod_cidrs=${pod_cidrs_json}"

k8s_setup_key="$(tofu output -raw -no-color k8s_setup_key)"
management_vm_setup_key="$(tofu output -raw -no-color management_vm_setup_key)"
proxy_setup_key="$(tofu output -raw -no-color proxy_setup_key)"
admins_group_id="$(tofu output -raw -no-color admins_group_id)"
management_vm_group_id="$(tofu output -raw -no-color management_vm_group_id)"
k8s_routers_group_id="$(tofu output -raw -no-color k8s_routers_group_id)"
proxy_group_id="$(tofu output -raw -no-color proxy_group_id)"
traefik_resource_id="$(tofu output -raw -no-color traefik_resource_id)"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"
routing_secret="$secrets_dir/netbird-routing-peers-${cluster_id}.json"
admin_secret="$secrets_dir/netbird-admin-access-${cluster_id}.json"
proxy_secret="$secrets_dir/netbird-proxy-access-${cluster_id}.json"
network_secret="$secrets_dir/netbird-network-${cluster_id}.json"

jq -n \
  --arg setup_key "$k8s_setup_key" \
  --arg management_url "$netbird_management_url" \
  --arg cluster_id "$cluster_id" \
  '{NB_SETUP_KEY: $setup_key, NB_MANAGEMENT_URL: $management_url, CLUSTER_ID: $cluster_id}' >"$routing_secret"

jq -n \
  --arg setup_key "$management_vm_setup_key" \
  --arg management_url "$netbird_management_url" \
  --arg cluster_id "$cluster_id" \
  '{NB_SETUP_KEY: $setup_key, NB_MANAGEMENT_URL: $management_url, CLUSTER_ID: $cluster_id}' >"$admin_secret"

jq -n \
  --arg setup_key "$proxy_setup_key" \
  --arg management_url "$netbird_management_url" \
  --arg hostname "twinbox-${cluster_id}-proxy" \
  --arg cluster_id "$cluster_id" \
  '{NB_SETUP_KEY: $setup_key, NB_MANAGEMENT_URL: $management_url, NB_HOSTNAME: $hostname, CLUSTER_ID: $cluster_id}' >"$proxy_secret"

chmod 600 "$routing_secret" "$admin_secret" "$proxy_secret"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "netbird-routing-peers" \
  --json-file "$routing_secret" \
  --required-keys "NB_SETUP_KEY,NB_MANAGEMENT_URL"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "netbird-admin-access" \
  --json-file "$admin_secret" \
  --required-keys "NB_SETUP_KEY,NB_MANAGEMENT_URL"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "netbird-proxy-access" \
  --json-file "$proxy_secret" \
  --required-keys "NB_SETUP_KEY,NB_MANAGEMENT_URL,NB_HOSTNAME"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing network secret for helper scripts"
jq -n \
  --arg management_url "$netbird_management_url" \
  --arg traefik_address "$traefik_resource_address" \
  --arg traefik_network_resource_address "$traefik_network_resource_address" \
  --arg traefik_target_port "$traefik_target_port" \
  --arg traefik_resource_id "$traefik_resource_id" \
  --argjson pod_cidrs "$pod_cidrs_json" \
  --arg admins_group_id "$admins_group_id" \
  --arg management_vm_group_id "$management_vm_group_id" \
  --arg k8s_routers_group_id "$k8s_routers_group_id" \
  --arg proxy_group_id "$proxy_group_id" \
  --arg cluster_id "$cluster_id" \
  '{
    NETBIRD_MANAGEMENT_URL: $management_url,
    TRAEFIK_RESOURCE_ADDRESS: $traefik_address,
    TRAEFIK_NETWORK_RESOURCE_ADDRESS: $traefik_network_resource_address,
    TRAEFIK_TARGET_PORT: $traefik_target_port,
    TRAEFIK_RESOURCE_ID: $traefik_resource_id,
    POD_CIDRS: $pod_cidrs,
    ADMINS_GROUP_ID: $admins_group_id,
    MANAGEMENT_VM_GROUP_ID: $management_vm_group_id,
    K8S_ROUTERS_GROUP_ID: $k8s_routers_group_id,
    PROXY_GROUP_ID: $proxy_group_id,
    CLUSTER_ID: $cluster_id
  }' >"$network_secret"
chmod 600 "$network_secret"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying NetBird routing peers before enabling reverse proxy"
wait_for_argocd_server
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/netbird-routing-peers.yaml" \
  --application "netbird-routing-peers" \
  --destination-namespace "argocd"
wait_for_netbird_routing_peer
wait_for_traefik_reverse_proxy_backend "$traefik_resource_address"
ensure_netbird_proxy_peer "$proxy_setup_key"
wait_for_netbird_proxy_backend \
  "$traefik_resource_address" \
  "$traefik_target_port" \
  "$authentik_domain" \
  "/application/o/netbird/.well-known/openid-configuration"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating wildcard DNS record for NetBird proxy"
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -

# Remove stale tunnel wildcard if transitioning from Cloudflare Tunnel
kubectl delete dnsendpoint cloudflare-tunnel-dns -n external-dns --ignore-not-found 2>/dev/null || true

# Create wildcard A record pointing all subdomains to the NetBird proxy
kubectl apply -f - <<EOF
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: netbird-wildcard-dns
  namespace: external-dns
spec:
  endpoints:
    - dnsName: "*.${public_zone_name}"
      recordType: A
      targets:
        - ${netbird_proxy_ip}
      recordTTL: 300
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating NetBird reverse proxy service for Authentik (required for OIDC verification)"
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "authentik" \
  --service-domain "$authentik_domain" \
  --service-path /

wait_for_public_oidc_discovery "$netbird_oidc_issuer"
wait_for_public_oidc_authorize "$authentik_public_url" "$netbird_oidc_client_id" "https://netbird.${public_zone_name}/oauth2/callback"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Registering Authentik as NetBird identity provider"
idp_workdir="$MANAGER_DATA_DIR/opentofu/netbird-idp-${cluster_id}"
mkdir -p "$idp_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird-idp/"* "$idp_workdir/"
cd "$idp_workdir"
tofu init -input=false -no-color
tofu apply -auto-approve -no-color \
  -var "netbird_token=$netbird_token" \
  -var "netbird_management_url=$netbird_management_url" \
  -var "client_id=$netbird_oidc_client_id" \
  -var "client_secret=$netbird_oidc_client_secret" \
  -var "issuer=$netbird_oidc_issuer"
identity_provider_id="$(tofu output -raw -no-color identity_provider_id)"

seed_netbird_account_for_sso "$identity_provider_id" "$netbird_admin_email"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as netbird"
cluster_file="$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
if [[ -f "$cluster_file" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "netbird"' "$cluster_file" >"$tmp_file"
  mv "$tmp_file" "$cluster_file"
fi

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg ingress_strategy "netbird" \
    --arg netbird_management_url "$netbird_management_url" \
    --arg traefik_resource_address "$traefik_resource_address" \
    --arg traefik_network_resource_address "$traefik_network_resource_address" \
    --arg traefik_target_port "$traefik_target_port" \
    --arg traefik_resource_id "$traefik_resource_id" \
    --argjson pod_cidrs "$pod_cidrs_json" \
    --arg cluster_id "$cluster_id" \
    '{
      status: $status,
      outputs: {
        ingress_strategy: $ingress_strategy,
        netbird_management_url: $netbird_management_url,
        traefik_resource_address: $traefik_resource_address,
        traefik_network_resource_address: $traefik_network_resource_address,
        traefik_target_port: $traefik_target_port,
        traefik_resource_id: $traefik_resource_id,
        pod_cidrs: $pod_cidrs,
        cluster_id: $cluster_id
      }
    }' >"$STEP_RESULT_FILE"
fi
