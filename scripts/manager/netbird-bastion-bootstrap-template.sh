#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
BOOTSTRAP_ENV="${NETBIRD_BOOTSTRAP_ENV:-/opt/netbird/.bootstrap.env}"
DNS_CREDENTIALS_FILE="${NETBIRD_DNS_CREDENTIALS_FILE:-/opt/netbird/.dns-credentials}"
TWINBOX_MARKER="/opt/netbird/.twinbox-bastion.json"

if [[ -f "$BOOTSTRAP_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_ENV"
  set +a
fi

: "${NETBIRD_DOMAIN:?missing NETBIRD_DOMAIN}"
: "${ADMIN_EMAIL:?missing ADMIN_EMAIL}"
: "${NETBIRD_VERSION:?missing NETBIRD_VERSION}"
: "${PROXY_DOMAIN:?missing PROXY_DOMAIN}"
: "${PUBLIC_ZONE_NAME:?missing PUBLIC_ZONE_NAME}"
: "${DNS_PROVIDER:?missing DNS_PROVIDER}"
ADMIN_TOKEN_EXPIRE_DAYS="${ADMIN_TOKEN_EXPIRE_DAYS:-365}"
OPKSSH_ISSUER_URL="${OPKSSH_ISSUER_URL:-}"
OPKSSH_CLIENT_ID="${OPKSSH_CLIENT_ID:-}"

retry_netbird_step() {
  local label="$1"
  shift
  local delay=5
  local max_attempts=8
  local attempt

  for attempt in $(seq 1 "$max_attempts"); do
    if "$@"; then
      return 0
    fi
    if [[ $attempt -eq $max_attempts ]]; then
      echo "ERROR: $label failed after $max_attempts attempts." >&2
      return 1
    fi
    printf 'WARNING: %s failed (attempt %s/%s); retrying in %ss...\n' "$label" "$attempt" "$max_attempts" "$delay" >&2
    sleep "$delay"
    delay=$((delay * 2))
    if [[ $delay -gt 60 ]]; then
      delay=60
    fi
  done
}

run_netbird_wildcard_lego() {
  local action="$1"
  shift

  case "$DNS_PROVIDER" in
    cloudflare)
      docker run --rm \
        -e "CLOUDFLARE_DNS_API_TOKEN=$DNS_API_TOKEN" \
        -v /opt/netbird/certs/lego:/data \
        goacme/lego:v4.27.0 \
        --path /data \
        --email "$ADMIN_EMAIL" \
        --dns "$DNS_PROVIDER" \
        --domains "$PUBLIC_ZONE_NAME" \
        --domains "*.$PUBLIC_ZONE_NAME" \
        --accept-tos \
        "$action" "$@"
      ;;
    aws)
      docker run --rm \
        -e "AWS_ACCESS_KEY_ID=$DNS_API_TOKEN" \
        -e "AWS_SECRET_ACCESS_KEY=$DNS_API_SECRET" \
        -v /opt/netbird/certs/lego:/data \
        goacme/lego:v4.27.0 \
        --path /data \
        --email "$ADMIN_EMAIL" \
        --dns "$DNS_PROVIDER" \
        --domains "$PUBLIC_ZONE_NAME" \
        --domains "*.$PUBLIC_ZONE_NAME" \
        --accept-tos \
        "$action" "$@"
      ;;
    digitalocean)
      docker run --rm \
        -e "DO_AUTH_TOKEN=$DNS_API_TOKEN" \
        -e "DO_TOKEN=$DNS_API_TOKEN" \
        -v /opt/netbird/certs/lego:/data \
        goacme/lego:v4.27.0 \
        --path /data \
        --email "$ADMIN_EMAIL" \
        --dns "$DNS_PROVIDER" \
        --domains "$PUBLIC_ZONE_NAME" \
        --domains "*.$PUBLIC_ZONE_NAME" \
        --accept-tos \
        "$action" "$@"
      ;;
    *)
      echo "ERROR: DNS provider $DNS_PROVIDER is not supported for NetBird wildcard certificates." >&2
      return 1
      ;;
  esac
}

install_netbird_wildcard_certificate() {
  local cert_name="$PUBLIC_ZONE_NAME"
  local cert_dir="/opt/netbird/certs/wildcard"
  local lego_dir="/opt/netbird/certs/lego"
  local lego_cert="$lego_dir/certificates/$cert_name.crt"
  local lego_key="$lego_dir/certificates/$cert_name.key"
  local cert_file="$cert_dir/$cert_name.crt"
  local key_file="$cert_dir/$cert_name.key"

  case "$DNS_PROVIDER" in
    cloudflare|aws|digitalocean)
      ;;
    *)
      echo "ERROR: DNS provider $DNS_PROVIDER is not supported for NetBird wildcard certificates." >&2
      return 1
      ;;
  esac

  install -d -m 0700 "$cert_dir" "$lego_dir"
  chown 1000:1000 "$cert_dir"
  set -a
  # shellcheck disable=SC1091
  source "$DNS_CREDENTIALS_FILE"
  set +a

  if [[ -s "$lego_cert" && -s "$lego_key" ]]; then
    retry_netbird_step "Renew NetBird wildcard certificate" \
      run_netbird_wildcard_lego renew --days 30
  else
    retry_netbird_step "Issue NetBird wildcard certificate" \
      run_netbird_wildcard_lego run
  fi

  if [[ ! -s "$lego_cert" || ! -s "$lego_key" ]]; then
    echo "ERROR: Lego did not produce the expected NetBird wildcard certificate files." >&2
    return 1
  fi

  install -m 0644 "$lego_cert" "$cert_file.tmp"
  install -m 0600 "$lego_key" "$key_file.tmp"
  chown 1000:1000 "$cert_file.tmp" "$key_file.tmp"
  mv -f "$cert_file.tmp" "$cert_file"
  mv -f "$key_file.tmp" "$key_file"
}

install_netbird_wildcard_renewal_timer() {
  cat >/usr/local/sbin/renew-netbird-wildcard-certificate <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /root/bootstrap-netbird.sh --renew-wildcard-certificate
EOF
  chmod 0755 /usr/local/sbin/renew-netbird-wildcard-certificate

  cat >/etc/systemd/system/netbird-wildcard-certificate.service <<'EOF'
[Unit]
Description=Renew NetBird wildcard certificate
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/renew-netbird-wildcard-certificate
EOF

  cat >/etc/systemd/system/netbird-wildcard-certificate.timer <<'EOF'
[Unit]
Description=Renew NetBird wildcard certificate daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now netbird-wildcard-certificate.timer
}

if [[ $# -gt 0 ]]; then
  if [[ "$1" == "--renew-wildcard-certificate" ]]; then
    install_netbird_wildcard_certificate
    exit 0
  fi
fi

seed_netbird_account_domain() {
  local volume_dir
  local store_db
  volume_dir="$(docker volume inspect netbird_netbird_data --format '{{ .Mountpoint }}' 2>/dev/null || true)"
  store_db="$volume_dir/store.db"
  if [[ -z "$volume_dir" || ! -f "$store_db" ]]; then
    echo "WARNING: NetBird store database not found; cannot seed account domain." >&2
    return 0
  fi

  python3 - "$store_db" "twinbox.internal" "$SETUP_RESULT" <<'PY'
import json
import sqlite3
import sys

store_db, peer_dns_domain, setup_result = sys.argv[1:4]
try:
    with open(setup_result, "r", encoding="utf-8") as handle:
        owner_user_id = json.load(handle).get("user_id", "")
except FileNotFoundError:
    owner_user_id = ""

if not owner_user_id:
    print("WARNING: NetBird setup result has no user_id; cannot seed account domain.", file=sys.stderr)
    raise SystemExit(0)

with sqlite3.connect(store_db) as connection:
    connection.row_factory = sqlite3.Row
    row = connection.execute(
        "select account_id from users where id = ?",
        (owner_user_id,),
    ).fetchone()
    if row is None:
        print("WARNING: NetBird owner user not found in store; cannot seed account domain.", file=sys.stderr)
        raise SystemExit(0)

    account_id = row["account_id"]
    connection.execute(
        "update accounts set domain = ?, domain_category = ?, is_domain_primary_account = 1, "
        "settings_extra_user_approval_required = 0 where id = ?",
        (peer_dns_domain, "private", account_id),
    )
    connection.execute(
        "update account_onboardings set onboarding_flow_pending = 0 where account_id = ?",
        (account_id,),
    )
    connection.commit()
    print(f"Seeded NetBird account {account_id} as private peer DNS domain {peer_dns_domain}.")
PY
}

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable docker
systemctl start docker

install -d -m 0755 /opt/netbird
cd /opt/netbird

if [[ -f /opt/netbird/docker-compose.yml ]]; then
  if [[ ! -f "$TWINBOX_MARKER" ]]; then
    echo "ERROR: /opt/netbird/docker-compose.yml exists but Twinbox ownership marker is missing." >&2
    echo "Refusing to overwrite an unmanaged NetBird installation." >&2
    exit 1
  fi
  if ! jq -e '.managed_by == "twinbox" and .component == "netbird-bastion"' "$TWINBOX_MARKER" >/dev/null; then
    echo "ERROR: /opt/netbird is not marked as a Twinbox-managed NetBird bastion." >&2
    exit 1
  fi
fi

jq -n   --arg managed_by "twinbox"   --arg component "netbird-bastion"   --arg netbird_domain "$NETBIRD_DOMAIN"   --arg proxy_domain "$PROXY_DOMAIN"   --arg public_zone_name "$PUBLIC_ZONE_NAME"   '{managed_by: $managed_by, component: $component, netbird_domain: $netbird_domain, proxy_domain: $proxy_domain, public_zone_name: $public_zone_name}'   >"$TWINBOX_MARKER.tmp"
mv -f "$TWINBOX_MARKER.tmp" "$TWINBOX_MARKER"
chmod 0644 "$TWINBOX_MARKER"

if [[ ! -f getting-started.sh ]]; then
  curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh -o getting-started.sh
  chmod 0755 getting-started.sh
fi

if [[ ! -f docker-compose.yml ]]; then
  python3 <<'PY'
import os
from pathlib import Path

path = Path("/opt/netbird/getting-started.sh")
script = path.read_text()
marker = "\ninit_environment\n"
overrides = (
    "\n"
    "# Twinbox non-interactive defaults.\n"
    "retry_netbird_step() {\n"
    '  local label="$1"\n'
    "  shift\n"
    "  local delay=5\n"
    "  local max_attempts=8\n"
    "  local attempt\n"
    '  for attempt in $(seq 1 "$max_attempts"); do\n'
    '    if "$@"; then\n'
    "      return 0\n"
    "    fi\n"
    '    if [[ $attempt -eq $max_attempts ]]; then\n'
    '      echo "ERROR: $label failed after $max_attempts attempts." >&2\n'
    "      return 1\n"
    "    fi\n"
    "    printf 'WARNING: %s failed (attempt %s/%s); retrying in %ss...\\n' \"$label\" \"$attempt\" \"$max_attempts\" \"$delay\" >&2\n"
    '    sleep "$delay"\n'
    "    delay=$((delay * 2))\n"
    "    if [[ $delay -gt 60 ]]; then\n"
    "      delay=60\n"
    "    fi\n"
    "  done\n"
    "}\n"
    "\n"
    "configure_reverse_proxy() {\n"
    '  REVERSE_PROXY_TYPE="0"\n'
    '  TRAEFIK_ACME_EMAIL="' + os.environ['ADMIN_EMAIL'] + '"\n'
    '  ENABLE_PROXY="true"\n'
    '  ENABLE_CROWDSEC="false"\n'
    "  return 0\n"
    "}\n"
)
if marker in script and "Twinbox non-interactive defaults" not in script:
    script = script.replace(marker, overrides + marker, 1)
proxy_start = "$DOCKER_COMPOSE_COMMAND up -d proxy"
proxy_retry = 'retry_netbird_step "Start NetBird reverse proxy" $DOCKER_COMPOSE_COMMAND up -d proxy'
if proxy_retry not in script:
    lines = []
    replaced = False
    for line in script.splitlines():
        if line.strip() == proxy_start:
            lines.append(line[: len(line) - len(line.lstrip())] + proxy_retry)
            replaced = True
        else:
            lines.append(line)
    if not replaced:
        raise SystemExit("ERROR: Could not patch NetBird reverse proxy startup for retries.")
    script = "\n".join(lines) + "\n"
if marker not in script:
    raise SystemExit("ERROR: Could not find NetBird init_environment marker.")
path.write_text(script)
PY
  ./getting-started.sh
fi

if [[ -f /opt/netbird/docker-compose.yml ]]; then
  sed -i "s|netbirdio/netbird:latest|netbirdio/netbird:$NETBIRD_VERSION|g" /opt/netbird/docker-compose.yml 2>/dev/null || true

  python3 <<'PY'
import os
import yaml
from pathlib import Path

path = Path("/opt/netbird/docker-compose.yml")
compose = yaml.safe_load(path.read_text())
services = compose.get("services", {})
netbird_domain = os.environ["NETBIRD_DOMAIN"]
dns_provider = os.environ["DNS_PROVIDER"]
creds = {}
creds_path = Path("/opt/netbird/.dns-credentials")
if creds_path.exists():
    for line in creds_path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            creds[k] = v
dns_api_token = creds.get("DNS_API_TOKEN", "")
dns_api_secret = creds.get("DNS_API_SECRET", "")

traefik = services.get("traefik", {})

# Add DNS-01 challenge arguments to traefik command
command = traefik.get("command", [])
command_args = {
    "--providers.docker.network=": "--providers.docker.network=netbird_netbird",
    "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=": (
        f"--certificatesresolvers.letsencrypt.acme.dnschallenge.provider={dns_provider}"
    ),
    "--providers.file.filename=": "--providers.file.filename=/opt/netbird/traefik-dynamic.yaml",
}
if isinstance(command, list):
    for prefix, desired_arg in command_args.items():
        replaced = False
        next_command = []
        for arg in command:
            if isinstance(arg, str) and arg.startswith(prefix):
                if not replaced:
                    next_command.append(desired_arg)
                    replaced = True
            else:
                next_command.append(arg)
        if not replaced:
            next_command.append(desired_arg)
        command = next_command
elif isinstance(command, str):
    existing_args = command.split()
    for prefix, desired_arg in command_args.items():
        kept_args = [arg for arg in existing_args if not arg.startswith(prefix)]
        kept_args.append(desired_arg)
        existing_args = kept_args
    command = " ".join(existing_args)
else:
    command = list(command_args.values())
traefik["command"] = command

volumes = traefik.setdefault("volumes", [])
cert_volume = "/opt/netbird/certs:/certs:ro"
dynamic_volume = "/opt/netbird/traefik-dynamic.yaml:/opt/netbird/traefik-dynamic.yaml:ro"
if isinstance(volumes, list):
    for volume in (cert_volume, dynamic_volume):
        if volume not in volumes:
            volumes.append(volume)

def ensure_network_alias(service, network_name, alias):
    networks = service.get("networks")
    if networks is None:
        networks = {}
        service["networks"] = networks
    if isinstance(networks, list):
        next_networks = {}
        for item in networks:
            if isinstance(item, str):
                next_networks.setdefault(item, {})
            elif isinstance(item, dict):
                for key, value in item.items():
                    next_networks[key] = value or {}
        networks = next_networks
        service["networks"] = networks
    if isinstance(networks, dict):
        entry = networks.get(network_name)
        if entry is None:
            entry = {}
            networks[network_name] = entry
        elif isinstance(entry, list):
            entry = {"aliases": entry}
            networks[network_name] = entry
        elif not isinstance(entry, dict):
            entry = {}
            networks[network_name] = entry
        aliases = entry.setdefault("aliases", [])
        if not isinstance(aliases, list):
            aliases = [aliases]
            entry["aliases"] = aliases
        if alias not in aliases:
            aliases.append(alias)

ensure_network_alias(traefik, "netbird", netbird_domain)

# Add DNS provider environment variables to traefik
env = traefik.setdefault("environment", [])
if isinstance(env, list):
    env_vars = {}
    for item in env:
        if "=" in item:
            k, v = item.split("=", 1)
            env_vars[k] = v
    provider_env = {
        "cloudflare": {"CLOUDFLARE_DNS_API_TOKEN": dns_api_token},
        "aws": {"AWS_ACCESS_KEY_ID": dns_api_token, "AWS_SECRET_ACCESS_KEY": dns_api_secret},
        "digitalocean": {"DO_AUTH_TOKEN": dns_api_token, "DO_TOKEN": dns_api_token},
    }
    for k, v in provider_env.get(dns_provider, {}).items():
        if v and k not in env_vars:
            env.append(f"{k}={v}")
elif isinstance(env, dict):
    provider_env = {
        "cloudflare": {"CLOUDFLARE_DNS_API_TOKEN": dns_api_token},
        "aws": {"AWS_ACCESS_KEY_ID": dns_api_token, "AWS_SECRET_ACCESS_KEY": dns_api_secret},
        "digitalocean": {"DO_AUTH_TOKEN": dns_api_token, "DO_TOKEN": dns_api_token},
    }
    for k, v in provider_env.get(dns_provider, {}).items():
        if v:
            env.setdefault(k, v)

def remove_label_keys(service, predicate):
    labels = service.setdefault("labels", [])
    if isinstance(labels, list):
        labels[:] = [
            item for item in labels
            if "=" not in item or not predicate(item.split("=", 1)[0])
        ]
    elif isinstance(labels, dict):
        for key in list(labels):
            if predicate(key):
                labels.pop(key, None)

def set_labels(service, updates):
    labels = service.setdefault("labels", [])
    if isinstance(labels, list):
        labels[:] = [
            item for item in labels
            if "=" not in item or item.split("=", 1)[0] not in updates
        ]
        for key, value in updates.items():
            labels.append(f"{key}={value}")
    elif isinstance(labels, dict):
        for key, value in updates.items():
            labels[key] = value

def get_label(service, key):
    labels = service.get("labels", [])
    if isinstance(labels, list):
        for item in labels:
            if "=" not in item:
                continue
            item_key, item_value = item.split("=", 1)
            if item_key == key:
                return item_value
    elif isinstance(labels, dict):
        return labels.get(key, "")
    return ""

def append_csv_label_value(service, key, value):
    existing = get_label(service, key)
    parts = [part.strip() for part in existing.split(",") if part.strip()]
    if value not in parts:
        parts.append(value)
    set_labels(service, {key: ",".join(parts)})

def is_removed_http_wildcard_label(key):
    removed_prefixes = (
        "traefik.http.routers." + "wildcard.",
        "traefik.http.services." + "cluster" + "-proxy.",
        "traefik.http.serverstransports." + "proxy-insecure.",
    )
    return key.startswith(removed_prefixes)

remove_label_keys(traefik, is_removed_http_wildcard_label)

netbird_no_store_middleware = "netbird-no-store"
no_store_middleware_labels = {
    "traefik.http.middlewares.netbird-no-store.headers.customresponseheaders.Cache-Control": (
        "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0"
    ),
    "traefik.http.middlewares.netbird-no-store.headers.customresponseheaders.Pragma": "no-cache",
    "traefik.http.middlewares.netbird-no-store.headers.customresponseheaders.Expires": "0",
}
remove_label_keys(
    traefik,
    lambda key: key.startswith("traefik.http.middlewares.netbird-no-store."),
)

dashboard_tls_domain_labels = {
    "traefik.http.routers.netbird-dashboard.tls.domains[0].main": netbird_domain,
}
server_tls_domain_labels = {
    "traefik.http.routers.netbird-backend.tls.domains[0].main": netbird_domain,
    "traefik.http.routers.netbird-grpc.tls.domains[0].main": netbird_domain,
}
dashboard = services.get("dashboard")
if dashboard:
    remove_label_keys(dashboard, lambda key: key.startswith("traefik.http.routers.netbird-dashboard.tls.domains["))
    set_labels(dashboard, dashboard_tls_domain_labels)
    append_csv_label_value(
        dashboard,
        "traefik.http.routers.netbird-dashboard.middlewares",
        netbird_no_store_middleware,
    )

netbird_server = services.get("netbird-server")
if netbird_server:
    remove_label_keys(netbird_server, lambda key: (
        key.startswith("traefik.http.routers.netbird-backend.tls.domains[")
        or key.startswith("traefik.http.routers.netbird-grpc.tls.domains[")
    ))
    set_labels(netbird_server, {**server_tls_domain_labels, **no_store_middleware_labels})
    append_csv_label_value(
        netbird_server,
        "traefik.http.routers.netbird-backend.middlewares",
        netbird_no_store_middleware,
    )
    append_csv_label_value(
        netbird_server,
        "traefik.http.routers.netbird-grpc.middlewares",
        netbird_no_store_middleware,
    )

proxy = services.get("proxy")
if proxy:
    passthrough_label = "traefik.tcp.routers.proxy-passthrough.rule"
    passthrough_rule = f"HostSNI(`*`) && !HostSNI(`{netbird_domain}`)"
    remove_label_keys(proxy, is_removed_http_wildcard_label)
    set_labels(proxy, {passthrough_label: passthrough_rule})
    volumes = proxy.setdefault("volumes", [])
    wildcard_volume = "/opt/netbird/certs/wildcard:/wildcard-certs:ro"
    if isinstance(volumes, list) and wildcard_volume not in volumes:
        volumes.append(wildcard_volume)

# Add NB_SETUP_PAT_ENABLED to netbird-server
if "netbird-server" in services:
    env = services["netbird-server"].setdefault("environment", [])
    if isinstance(env, list):
        if not any("NB_SETUP_PAT_ENABLED" in e for e in env):
            env.append("NB_SETUP_PAT_ENABLED=true")
    elif isinstance(env, dict):
        env.setdefault("NB_SETUP_PAT_ENABLED", "true")

path.write_text(yaml.dump(compose, default_flow_style=False, sort_keys=False))
PY

  python3 <<'PY'
import os
import yaml
from pathlib import Path

path = Path("/opt/netbird/traefik-dynamic.yaml")
if path.exists():
    data = yaml.safe_load(path.read_text()) or {}
else:
    data = {}
data.pop("tls", None)
data.pop("http", None)
tcp = data.setdefault("tcp", {})
transports = tcp.setdefault("serversTransports", {})
pp_v2 = transports.setdefault("pp-v2", {})
pp_v2["proxyProtocol"] = {"version": 2}
path.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))
PY
fi

if [[ -f proxy.env ]]; then
  python3 <<'PY'
import os
from pathlib import Path

path = Path("/opt/netbird/proxy.env")
lines = path.read_text().splitlines()
updates = {
    "NB_PROXY_DOMAIN": "'" + os.environ['PROXY_DOMAIN'] + "'",
    "NB_PROXY_ACME_CERTIFICATES": "true",
    "NB_PROXY_ACME_CHALLENGE_TYPE": "tls-alpn-01",
    "NB_PROXY_CERTIFICATE_DIRECTORY": "/certs",
    "NB_PROXY_WILDCARD_CERT_DIR": "/wildcard-certs",
}
seen = set()
out = []
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0].strip()
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PY
fi

install_netbird_wildcard_certificate
install_netbird_wildcard_renewal_timer
retry_netbird_step "Pull NetBird compose images" docker compose pull
docker compose up -d

NETBIRD_URL="https://$NETBIRD_DOMAIN"
NETBIRD_SERVER_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' netbird-server)"
if [[ -z "$NETBIRD_SERVER_IP" ]]; then
  echo "ERROR: Could not determine netbird-server container IP." >&2
  exit 1
fi
BOOTSTRAP_NETBIRD_URL="http://$NETBIRD_SERVER_IP"
SETUP_RESULT="/opt/netbird/setup-result.json"

echo "Waiting for NetBird server to become ready..."
for i in $(seq 1 120); do
  if curl -fsS -H "Host: $NETBIRD_DOMAIN" -o /dev/null "$BOOTSTRAP_NETBIRD_URL/oauth2/.well-known/openid-configuration" 2>/dev/null; then
    echo "NetBird server is ready."
    break
  fi
  if [[ $i -eq 120 ]]; then
    echo "ERROR: NetBird server did not become ready in time." >&2
    exit 1
  fi
  echo -n "."
  sleep 5
done
echo

if [[ -s "$SETUP_RESULT" ]] && jq -e '.personal_access_token // empty' "$SETUP_RESULT" >/dev/null 2>&1; then
  echo "Reusing existing NetBird setup result with personal access token."
  SETUP_RESPONSE="$(cat "$SETUP_RESULT")"
else
  ADMIN_PASSWORD="$(openssl rand -base64 32 | sed 's/=//g')"
  echo "Calling NetBird automated setup API..."
  SETUP_RESPONSE="$(curl -fsS -X POST "$BOOTSTRAP_NETBIRD_URL/api/setup" \
    -H "Host: $NETBIRD_DOMAIN" \
    -H "Content-Type: application/json" \
    -d '{
      "email": "'"$ADMIN_EMAIL"'",
      "name": "Twinbox Admin",
      "password": "'"$ADMIN_PASSWORD"'",
      "create_pat": true,
      "pat_expire_in": ${ADMIN_TOKEN_EXPIRE_DAYS}
    }')"

  echo "$SETUP_RESPONSE" > "$SETUP_RESULT"
  chmod 600 "$SETUP_RESULT"
fi
seed_netbird_account_domain

if ! echo "$SETUP_RESPONSE" | jq -e '.personal_access_token' >/dev/null 2>&1; then
  echo "ERROR: Setup did not return a personal access token." >&2
  echo "$SETUP_RESPONSE" >&2
  exit 1
fi
echo "NetBird automated setup completed successfully."

echo "Checking public NetBird TLS endpoint..."
if curl -fsS -o /dev/null "$NETBIRD_URL/oauth2/.well-known/openid-configuration" 2>/dev/null; then
  echo "Public NetBird TLS endpoint is ready."
else
  echo "WARNING: NetBird setup completed, but public TLS is not trusted or reachable yet. This is often temporary during Let's Encrypt issuance or rate limiting." >&2
fi
