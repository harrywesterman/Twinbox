#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: sync-pgadmin4-server.sh --app-id ID --host HOST [--username USER] [--maintenance-db DB] [--server-name NAME] [--comment TEXT]
USAGE
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

APP_ID=""
HOST=""
USERNAME=""
SHARED_USERNAME=""
MAINTENANCE_DB="postgres"
SERVER_NAME=""
COMMENT=""
GROUP_NAME="Shared Servers"
PORT="5432"
SSL_MODE="prefer"
SOURCE_NAMESPACE="databases"
SOURCE_SECRET=""
SOURCE_KEY="password"
PGADMIN_NAMESPACE="pgadmin4"
PGADMIN_SECRET_NAME="pgadmin4-db-password"
PGADMIN_CONFIGMAP_NAME="pgadmin4-servers"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)
      APP_ID="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --username)
      USERNAME="$2"
      shift 2
      ;;
    --shared-username)
      SHARED_USERNAME="$2"
      shift 2
      ;;
    --maintenance-db)
      MAINTENANCE_DB="$2"
      shift 2
      ;;
    --server-name)
      SERVER_NAME="$2"
      shift 2
      ;;
    --comment)
      COMMENT="$2"
      shift 2
      ;;
    --group)
      GROUP_NAME="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --ssl-mode)
      SSL_MODE="$2"
      shift 2
      ;;
    --source-namespace)
      SOURCE_NAMESPACE="$2"
      shift 2
      ;;
    --source-secret)
      SOURCE_SECRET="$2"
      shift 2
      ;;
    --source-key)
      SOURCE_KEY="$2"
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

[[ -n "$APP_ID" ]] || fail "--app-id is required"
[[ -n "$HOST" ]] || fail "--host is required"

USERNAME="${USERNAME:-$APP_ID}"
SHARED_USERNAME="${SHARED_USERNAME:-$USERNAME}"
SERVER_NAME="${SERVER_NAME:-$(case "$APP_ID" in
  openwebui) printf '%s\n' 'CloudNativePG - OpenWebUI' ;;
  hedgedoc) printf '%s\n' 'CloudNativePG - HedgeDoc' ;;
  immich) printf '%s\n' 'CloudNativePG - Immich' ;;
  n8n) printf '%s\n' 'CloudNativePG - n8n' ;;
  nextcloud) printf '%s\n' 'CloudNativePG - Nextcloud' ;;
  outline) printf '%s\n' 'CloudNativePG - Outline' ;;
  paperless) printf '%s\n' 'CloudNativePG - Paperless' ;;
  pixelfed) printf '%s\n' 'CloudNativePG - Pixelfed' ;;
  vaultwarden) printf '%s\n' 'CloudNativePG - Vaultwarden' ;;
  zulip) printf '%s\n' 'CloudNativePG - Zulip' ;;
  *) printf 'CloudNativePG - %s\n' "$APP_ID" ;;
esac)}"
COMMENT="${COMMENT:-$(case "$APP_ID" in
  openwebui) printf '%s\n' 'CloudNativePG pooler for the OpenWebUI cluster' ;;
  hedgedoc) printf '%s\n' 'CloudNativePG pooler for the HedgeDoc cluster' ;;
  immich) printf '%s\n' 'CloudNativePG pooler for the Immich cluster' ;;
  n8n) printf '%s\n' 'CloudNativePG pooler for the n8n cluster' ;;
  nextcloud) printf '%s\n' 'CloudNativePG pooler for the Nextcloud cluster' ;;
  outline) printf '%s\n' 'CloudNativePG pooler for the Outline cluster' ;;
  paperless) printf '%s\n' 'CloudNativePG pooler for the Paperless cluster' ;;
  pixelfed) printf '%s\n' 'CloudNativePG pooler for the Pixelfed cluster' ;;
  vaultwarden) printf '%s\n' 'CloudNativePG pooler for the Vaultwarden cluster' ;;
  zulip) printf '%s\n' 'CloudNativePG pooler for the Zulip cluster' ;;
  *) printf 'CloudNativePG pooler for the %s cluster\n' "$APP_ID" ;;
esac)}"
SOURCE_SECRET="${SOURCE_SECRET:-${APP_ID}-db-credentials}"
PGADMIN_SECRET_KEY="PGADMIN_${APP_ID^^}_DB_PASSWORD"
SOURCE_SECRET_VALUE=""
current_secret_string_data="{}"
current_configmap_doc='{"Servers":{}}'

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE does not exist at ${KUBECONFIG_FILE:-}"
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

if ! kubectl -n "$SOURCE_NAMESPACE" get secret "$SOURCE_SECRET" >/dev/null 2>&1; then
  log "Source secret ${SOURCE_NAMESPACE}/${SOURCE_SECRET} not found; skipping pgAdmin refresh"
  exit 0
fi

if ! kubectl -n "$PGADMIN_NAMESPACE" get configmap "$PGADMIN_CONFIGMAP_NAME" >/dev/null 2>&1; then
  log "pgAdmin configmap not found; skipping pgAdmin refresh"
  exit 0
fi

if ! kubectl -n "$PGADMIN_NAMESPACE" get secret "$PGADMIN_SECRET_NAME" >/dev/null 2>&1; then
  log "pgAdmin password secret not found; skipping pgAdmin refresh"
  exit 0
fi

SOURCE_SECRET_VALUE="$(
  kubectl -n "$SOURCE_NAMESPACE" get secret "$SOURCE_SECRET" -o jsonpath="{.data.${SOURCE_KEY}}" | base64 -d
)"

current_secret_json="$(
  kubectl -n "$PGADMIN_NAMESPACE" get secret "$PGADMIN_SECRET_NAME" -o json
)"
current_secret_string_data="$(
  jq -c '.data // {} | with_entries(.value |= @base64d)' <<<"$current_secret_json"
)"
updated_secret_string_data="$(
  jq -cn \
    --argjson current "$current_secret_string_data" \
    --arg key "$PGADMIN_SECRET_KEY" \
    --arg value "$SOURCE_SECRET_VALUE" \
    '$current | .[$key] = $value'
)"

if [[ "$(jq -cS . <<<"$current_secret_string_data")" != "$(jq -cS . <<<"$updated_secret_string_data")" ]]; then
  secret_manifest="$(
    jq -cn \
      --argjson string_data "$updated_secret_string_data" \
      '{
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
          name: "pgadmin4-db-password",
          namespace: "pgadmin4"
        },
        type: "Opaque",
        stringData: $string_data
      }'
  )"
  printf '%s\n' "$secret_manifest" | kubectl apply -f - >/dev/null
  log "Updated pgAdmin password secret for ${APP_ID}"
fi

current_configmap_json="$(
  kubectl -n "$PGADMIN_NAMESPACE" get configmap "$PGADMIN_CONFIGMAP_NAME" -o json
)"
current_configmap_doc="$(
  jq -c '.data["pgadmin4-servers.json"] | fromjson' <<<"$current_configmap_json"
)"

server_doc="$(
  jq -cn \
    --arg name "$SERVER_NAME" \
    --arg group "$GROUP_NAME" \
    --arg host "$HOST" \
    --argjson port "$PORT" \
    --arg maintenance_db "$MAINTENANCE_DB" \
    --arg username "$USERNAME" \
    --arg shared_username "$SHARED_USERNAME" \
    --arg password_exec_command "printf %s \"\$$PGADMIN_SECRET_KEY\"" \
    --arg ssl_mode "$SSL_MODE" \
    --arg comment "$COMMENT" \
    '{
      Name: $name,
      Group: $group,
      Host: $host,
      Port: $port,
      MaintenanceDB: $maintenance_db,
      Username: $username,
      SharedUsername: $shared_username,
      PasswordExecCommand: $password_exec_command,
      Shared: true,
      ConnectionParameters: {
        sslmode: $ssl_mode
      },
      Comment: $comment
    }'
)"

updated_configmap_doc="$(
  jq -cn \
    --argjson current "$current_configmap_doc" \
    --argjson server "$server_doc" \
    --arg server_name "$SERVER_NAME" \
    --arg host "$HOST" \
    '
      ($current.Servers // {}) as $servers
      | ([ $servers | to_entries[]? | select(.value.Name == $server_name or .value.Host == $host) | .key ][0]) as $existing_key
      | if $existing_key != null then
          $current | .Servers[$existing_key] = $server
        else
          $current | .Servers[(([$servers | keys[]? | tonumber] | max // 0) + 1 | tostring)] = $server
        end
    '
)"

if [[ "$(jq -cS . <<<"$current_configmap_doc")" != "$(jq -cS . <<<"$updated_configmap_doc")" ]]; then
  configmap_manifest="$(
    jq -cn \
      --argjson servers_doc "$updated_configmap_doc" \
      '{
        apiVersion: "v1",
        kind: "ConfigMap",
        metadata: {
          name: "pgadmin4-servers",
          namespace: "pgadmin4"
        },
        data: {
          "pgadmin4-servers.json": ($servers_doc | tojson)
        }
      }'
  )"
  printf '%s\n' "$configmap_manifest" | kubectl apply -f - >/dev/null
  log "Updated pgAdmin server list for ${APP_ID}"
fi

if kubectl -n "$PGADMIN_NAMESPACE" get deployment pgadmin4 >/dev/null 2>&1; then
  kubectl -n "$PGADMIN_NAMESPACE" rollout restart deployment/pgadmin4 >/dev/null
  kubectl -n "$PGADMIN_NAMESPACE" rollout status deployment/pgadmin4 --timeout=10m >/dev/null
  log "pgAdmin refreshed for ${APP_ID}"
else
  log "pgAdmin deployment not found; skipping restart after updating metadata for ${APP_ID}"
fi
