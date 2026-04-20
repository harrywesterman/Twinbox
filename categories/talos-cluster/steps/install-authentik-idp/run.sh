#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

export KUBECONFIG="$KUBECONFIG_FILE"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
authentik_secret_file="$BOOTSTRAP_ROOT/secrets/global/authentik.json"
openbao_initialized_file="$BOOTSTRAP_ROOT/openbao/init/initialized.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/authentik.yaml"
databases_namespace_manifest="$WORKSPACE_ROOT/gitops/databases/namespace.yaml"
longhorn_single_storageclass_manifest="$WORKSPACE_ROOT/gitops/databases/longhorn-single-storageclass.yaml"
authentik_db_cluster_manifest="$WORKSPACE_ROOT/gitops/databases/authentik/cluster.yaml"
authentik_db_externalsecret_manifest="$WORKSPACE_ROOT/gitops/databases/authentik/externalsecret.yaml"
authentik_db_pooler_ro_manifest="$WORKSPACE_ROOT/gitops/databases/authentik/pooler-ro.yaml"
authentik_db_pooler_rw_manifest="$WORKSPACE_ROOT/gitops/databases/authentik/pooler-rw.yaml"
authentik_db_pooler_rw_session_manifest="$WORKSPACE_ROOT/gitops/databases/authentik/pooler-rw-session.yaml"
authentik_db_backup_manifest="$WORKSPACE_ROOT/gitops/databases/authentik/scheduled-backup.yaml"
authentik_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform/authentik/externalsecret.yaml"
authentik_ingressroute_manifest="$WORKSPACE_ROOT/gitops/platform/authentik/ingressroute.yaml"

mkdir -p "$(dirname "$authentik_secret_file")"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

wait_for_resources_ready() {
  local namespace="$1"
  local kind="$2"
  local condition="$3"
  local label="$4"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" get "$kind" -o name 2>/dev/null | grep -q .; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$kind" --all --timeout=5s >/dev/null 2>&1; then
        log "${label} resources are ready"
        return 0
      fi

      log "Waiting for ${label} resources to become ready"
    else
      log "Waiting for ${label} resources to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} resources did not become ready after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

authentik_host="${TWINBOX_AUTHENTIK_HOST:-}"
if [[ -z "$authentik_host" && -n "$cluster_dns_domain" ]]; then
  public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
  [[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

  authentik_host="https://authentik.${public_zone_name}"
fi
authentik_secret_key=""
authentik_bootstrap_password=""
authentik_bootstrap_token=""
authentik_bootstrap_email=""
authentik_automation_token_key=""
authentik_postgresql_host=""
authentik_postgresql_port=""
authentik_postgresql_name=""
authentik_postgresql_user=""
authentik_postgresql_password=""
authentik_postgresql_disable_server_side_cursors=""
authentik_postgresql_conn_max_age=""

load_authentik_secret_json() {
  local secret_json="$1"

  authentik_secret_key="$(jq -r '.AUTHENTIK_SECRET_KEY // empty' <<<"$secret_json")"
  authentik_bootstrap_password="$(jq -r '.AUTHENTIK_BOOTSTRAP_PASSWORD // empty' <<<"$secret_json")"
  authentik_bootstrap_token="$(jq -r '.AUTHENTIK_BOOTSTRAP_TOKEN // empty' <<<"$secret_json")"
  authentik_bootstrap_email="$(jq -r '.AUTHENTIK_BOOTSTRAP_EMAIL // empty' <<<"$secret_json")"
  authentik_automation_token_key="$(jq -r '.AUTHENTIK_AUTOMATION_TOKEN_KEY // empty' <<<"$secret_json")"
  authentik_postgresql_host="$(jq -r '.AUTHENTIK_POSTGRESQL__HOST // empty' <<<"$secret_json")"
  authentik_postgresql_port="$(jq -r '.AUTHENTIK_POSTGRESQL__PORT // empty' <<<"$secret_json")"
  authentik_postgresql_name="$(jq -r '.AUTHENTIK_POSTGRESQL__NAME // empty' <<<"$secret_json")"
  authentik_postgresql_user="$(jq -r '.AUTHENTIK_POSTGRESQL__USER // .AUTHENTIK_POSTGRESQL__USERNAME // empty' <<<"$secret_json")"
  authentik_postgresql_password="$(jq -r '.AUTHENTIK_POSTGRESQL__PASSWORD // empty' <<<"$secret_json")"
  authentik_postgresql_disable_server_side_cursors="$(jq -r '.AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS // empty' <<<"$secret_json")"
  authentik_postgresql_conn_max_age="$(jq -r '.AUTHENTIK_POSTGRESQL__CONN_MAX_AGE // empty' <<<"$secret_json")"
}

if [[ -f "$authentik_secret_file" ]]; then
  load_authentik_secret_json "$(jq -c '.' "$authentik_secret_file")"
elif [[ -f "$openbao_initialized_file" ]]; then
  if authentik_secret_json="$(openbao_read_global_secret_json authentik 2>/dev/null || true)"; then
    if [[ -n "$authentik_secret_json" && "$authentik_secret_json" != "null" ]]; then
      load_authentik_secret_json "$authentik_secret_json"
    fi
  fi
fi

if [[ -z "$authentik_secret_key" ]]; then
  authentik_secret_key="$(openssl rand -hex 32)"
fi

if [[ -z "$authentik_bootstrap_password" ]]; then
  authentik_bootstrap_password="$(openssl rand -hex 16)"
fi

if [[ -z "$authentik_bootstrap_token" ]]; then
  authentik_bootstrap_token="$(openssl rand -hex 16)"
fi

if [[ -z "$authentik_bootstrap_email" ]]; then
  authentik_bootstrap_email="akadmin@twinbox.local"
fi

if [[ -z "$authentik_automation_token_key" ]]; then
  authentik_automation_token_key="$(openssl rand -hex 32)"
fi

if [[ -z "$authentik_postgresql_host" ]]; then
  authentik_postgresql_host="authentik-db-pooler-rw-session.databases.svc.cluster.local"
elif [[ "$authentik_postgresql_host" == "authentik-db-pooler-rw.databases.svc.cluster.local" ]]; then
  authentik_postgresql_host="authentik-db-pooler-rw-session.databases.svc.cluster.local"
fi

if [[ -z "$authentik_postgresql_port" ]]; then
  authentik_postgresql_port="5432"
fi

if [[ -z "$authentik_postgresql_name" ]]; then
  authentik_postgresql_name="authentik"
fi

if [[ -z "$authentik_postgresql_user" ]]; then
  authentik_postgresql_user="authentik"
fi

if [[ -z "$authentik_postgresql_password" ]]; then
  authentik_postgresql_password="$(openssl rand -hex 16)"
fi

if [[ -z "$authentik_postgresql_disable_server_side_cursors" ]]; then
  authentik_postgresql_disable_server_side_cursors="true"
fi

if [[ -z "$authentik_postgresql_conn_max_age" ]]; then
  authentik_postgresql_conn_max_age="0"
fi

if [[ -z "$authentik_host" ]]; then
  fail "Could not determine Authentik host; set DNS domain in the ingress selection step or override TWINBOX_AUTHENTIK_HOST"
fi

bootstrap_secret_file="$(mktemp)"
trap 'rm -f "$bootstrap_secret_file"' EXIT
jq -n \
  --arg authentik_secret_key "$authentik_secret_key" \
  --arg authentik_bootstrap_password "$authentik_bootstrap_password" \
  --arg authentik_bootstrap_token "$authentik_bootstrap_token" \
  --arg authentik_bootstrap_email "$authentik_bootstrap_email" \
  --arg authentik_automation_token_key "$authentik_automation_token_key" \
  --arg authentik_host "$authentik_host" \
  --arg authentik_postgresql_host "$authentik_postgresql_host" \
  --arg authentik_postgresql_port "$authentik_postgresql_port" \
  --arg authentik_postgresql_name "$authentik_postgresql_name" \
  --arg authentik_postgresql_user "$authentik_postgresql_user" \
  --arg authentik_postgresql_password "$authentik_postgresql_password" \
  --arg authentik_postgresql_disable_server_side_cursors "$authentik_postgresql_disable_server_side_cursors" \
  --arg authentik_postgresql_conn_max_age "$authentik_postgresql_conn_max_age" \
  '{
    "AUTHENTIK_SECRET_KEY": $authentik_secret_key,
    "AUTHENTIK_BOOTSTRAP_PASSWORD": $authentik_bootstrap_password,
    "AUTHENTIK_BOOTSTRAP_TOKEN": $authentik_bootstrap_token,
    "AUTHENTIK_BOOTSTRAP_EMAIL": $authentik_bootstrap_email,
    "AUTHENTIK_AUTOMATION_TOKEN_KEY": $authentik_automation_token_key,
    "AUTHENTIK_HOST": $authentik_host,
    "AUTHENTIK_HOST_BROWSER": $authentik_host,
    "AUTHENTIK_POSTGRESQL__HOST": $authentik_postgresql_host,
    "AUTHENTIK_POSTGRESQL__PORT": $authentik_postgresql_port,
    "AUTHENTIK_POSTGRESQL__NAME": $authentik_postgresql_name,
    "AUTHENTIK_POSTGRESQL__USER": $authentik_postgresql_user,
    "AUTHENTIK_POSTGRESQL__USERNAME": $authentik_postgresql_user,
    "AUTHENTIK_POSTGRESQL__PASSWORD": $authentik_postgresql_password,
    "AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS": $authentik_postgresql_disable_server_side_cursors,
    "AUTHENTIK_POSTGRESQL__CONN_MAX_AGE": $authentik_postgresql_conn_max_age
  }' >"$bootstrap_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "authentik" \
  --json-file "$bootstrap_secret_file" \
  --required-keys "AUTHENTIK_SECRET_KEY,AUTHENTIK_BOOTSTRAP_PASSWORD,AUTHENTIK_BOOTSTRAP_TOKEN,AUTHENTIK_BOOTSTRAP_EMAIL,AUTHENTIK_AUTOMATION_TOKEN_KEY,AUTHENTIK_HOST,AUTHENTIK_HOST_BROWSER,AUTHENTIK_POSTGRESQL__HOST,AUTHENTIK_POSTGRESQL__PORT,AUTHENTIK_POSTGRESQL__NAME,AUTHENTIK_POSTGRESQL__USER,AUTHENTIK_POSTGRESQL__USERNAME,AUTHENTIK_POSTGRESQL__PASSWORD,AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS,AUTHENTIK_POSTGRESQL__CONN_MAX_AGE"
rm -f "$bootstrap_secret_file" "$authentik_secret_file"
trap - EXIT

# Provision the PostgreSQL database cluster for Authentik
log "Creating database cluster and resources"
kubectl apply -f "$databases_namespace_manifest"
kubectl apply -f "$longhorn_single_storageclass_manifest"
kubectl apply -f "$authentik_db_cluster_manifest"
kubectl apply -f "$authentik_db_externalsecret_manifest"
kubectl apply -f "$authentik_db_pooler_ro_manifest"
kubectl apply -f "$authentik_db_pooler_rw_manifest"
kubectl apply -f "$authentik_db_pooler_rw_session_manifest"
kubectl apply -f "$authentik_db_backup_manifest"

wait_for_resources_ready "databases" "cluster" "Ready" "CloudNativePG cluster"
wait_for_resources_ready "databases" "externalsecret" "Ready" "ExternalSecret"
wait_for_resources_ready "databases" "deployment" "Available" "Pooler deployment"

kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$authentik_externalsecret_manifest"
kubectl apply -f "$authentik_ingressroute_manifest"

wait_for_secret() {
  local secret_name="$1"
  local label="${2:-$secret_name}"
  local attempts=60
  local attempt=1

  while true; do
    if kubectl -n authentik get secret "$secret_name" >/dev/null 2>&1; then
      log "${label} secret is ready"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      return 1
    fi

    log "Waiting for ${label} secret (${attempt}/${attempts})"
    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_secret "authentik-bootstrap" "Authentik bootstrap"

kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1 || fail "authentik-bootstrap secret did not appear after applying the ExternalSecret"

# Create the automation token Secret so the worker can read it via envFrom.
if [[ -n "$authentik_automation_token_key" ]]; then
  log "Creating authentik-automation-secret"
  kubectl -n authentik create secret generic authentik-automation-secret \
    --from-literal="AUTHENTIK_AUTOMATION_TOKEN=${authentik_automation_token_key}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "authentik"

wait_for_deployment_rollout() {
  local deployment="$1"
  local label="${2:-$deployment}"
  local attempts=120
  local attempt=1
  local status_json=""
  local desired_replicas=""
  local updated_replicas=""
  local ready_replicas=""
  local available_replicas=""
  local progressing_status=""
  local progressing_reason=""
  local available_status=""
  local available_reason=""
  local message=""

  while true; do
    if status_json="$(kubectl -n authentik get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"
      progressing_status="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .status // "Unknown"' <<<"$status_json")"
      progressing_reason="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .reason // empty' <<<"$status_json")"
      available_status="$(jq -r '.status.conditions[]? | select(.type == "Available") | .status // "Unknown"' <<<"$status_json")"
      available_reason="$(jq -r '.status.conditions[]? | select(.type == "Available") | .reason // empty' <<<"$status_json")"
      message="$(jq -r '.status.conditions[]? | select(.type == "Progressing" or .type == "Available") | .message // empty' <<<"$status_json" | awk 'NF { if (out) out = out " | "; out = out $0 } END { print out }')"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}, progressing=${progressing_status}${progressing_reason:+/${progressing_reason}}, available=${available_status}${available_reason:+/${available_reason}}${message:+, message=${message}}"
    else
      log "Waiting for ${label} deployment to appear (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for ${label}"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_deployment_rollout "authentik-server" "Authentik server"
wait_for_deployment_rollout "authentik-worker" "Authentik worker"

ensure_embedded_outpost_browser_host() {
  local outpost_json outpost_id current_config updated_config

  outpost_json="$(authentik_api_get "/outposts/instances/?page_size=100")"
  outpost_id="$(
    jq -r '
      .results[]?
      | select(.name == "authentik Embedded Outpost")
      | .pk // .id // empty
    ' <<<"$outpost_json" | head -n1
  )"
  [[ -n "$outpost_id" ]] || fail "Could not find the embedded Authentik outpost"

  current_config="$(
    jq -c --arg outpost_id "$outpost_id" '
      .results[]?
      | select((.pk // .id // "") == $outpost_id)
      | .config // {}
    ' <<<"$outpost_json" | head -n1
  )"
  [[ -n "$current_config" && "$current_config" != "null" ]] || current_config='{}'

  updated_config="$(
    jq -cn \
      --arg authentik_host "$authentik_host" \
      --argjson current_config "$current_config" \
      '$current_config + {authentik_host: $authentik_host, authentik_host_browser: $authentik_host}'
  )"

  log "Updating embedded Authentik outpost browser host to ${authentik_host}"
  authentik_api_write PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson config "$updated_config" '{config: $config}')" >/dev/null
}

# Argo CD syncs the blueprint ConfigMap via the third source in the Application manifest.
# Wait for the blueprint to be applied (service account appears via reconciliation).
if command -v openbao_read_global_secret_json >/dev/null 2>&1 && [[ -n "$authentik_automation_token_key" ]]; then
  current_secret="$(openbao_read_global_secret_json authentik)"
  updated_secret="$(printf '%s' "$current_secret" | jq \
    --arg api_token "$authentik_automation_token_key" \
    '. + {AUTHENTIK_API_TOKEN: $api_token}' \
  )"

  tmp_file="$(mktemp)"
  printf '%s' "$updated_secret" >"$tmp_file"

  log "Persisting AUTHENTIK_API_TOKEN in OpenBao from blueprint token key"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "authentik" \
    --json-file "$tmp_file" \
    --required-keys "AUTHENTIK_API_TOKEN"

  rm -f "$tmp_file"
fi

# Wait for the blueprint to be applied (service account appears via reconciliation).
# Uses the automation token directly (not the bootstrap token) since the blueprint
# already set the key on the token object.
wait_for_blueprint_service_account() {
  local attempts=60
  local attempt=1

  AUTHENTIK_LOCAL_FORWARD_PORT="${AUTHENTIK_LOCAL_FORWARD_PORT:-18299}"

  AUTHENTIK_API_BASE="http://127.0.0.1:${AUTHENTIK_LOCAL_FORWARD_PORT}/api/v3"
  AUTHENTIK_FORWARD_PID=""
  AUTHENTIK_FORWARD_LOG=""

  AUTHENTIK_FORWARD_LOG="$(mktemp "${TMPDIR:-/tmp}/authentik-port-forward.XXXXXX.log")"
  kubectl -n authentik port-forward "svc/authentik-server" "${AUTHENTIK_LOCAL_FORWARD_PORT}:80" >"$AUTHENTIK_FORWARD_LOG" 2>&1 &
  AUTHENTIK_FORWARD_PID="$!"

  local fwd_attempt=1
  local fwd_max=60
  while [[ "$fwd_attempt" -le "$fwd_max" ]]; do
    if curl -fsS "http://127.0.0.1:${AUTHENTIK_LOCAL_FORWARD_PORT}/-/health/live/" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
      if [[ -s "$AUTHENTIK_FORWARD_LOG" ]]; then
        tail -n 20 "$AUTHENTIK_FORWARD_LOG" >&2
      fi
      fail "Authentik port-forward did not become ready"
    fi
    sleep 1
    fwd_attempt=$((fwd_attempt + 1))
  done

  # Use the automation token directly (not the bootstrap token).
  local auth_token="$authentik_automation_token_key"

  while [[ "$attempt" -le "$attempts" ]]; do
    local sa_json
    sa_json="$(curl -sS \
      -H "Accept: application/json" \
      -H "Authorization: Bearer ${auth_token}" \
      "${AUTHENTIK_API_BASE}/core/users/?type=service_account&search=twinbox-automation" \
    2>/dev/null || true)"

    if [[ -n "$sa_json" ]] && printf '%s' "$sa_json" | jq -e '.results // [] | map(select(.username == "twinbox-automation")) | length > 0' >/dev/null 2>&1; then
      log "Blueprint service account 'twinbox-automation' detected – blueprint applied successfully"
      return 0
    fi

    if ! kill -0 "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1; then
      kill "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
      wait "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
      AUTHENTIK_FORWARD_LOG="$(mktemp "${TMPDIR:-/tmp}/authentik-port-forward.XXXXXX.log")"
      kubectl -n authentik port-forward "svc/authentik-server" "${AUTHENTIK_LOCAL_FORWARD_PORT}:80" >"$AUTHENTIK_FORWARD_LOG" 2>&1 &
      AUTHENTIK_FORWARD_PID="$!"
    fi

    log "Waiting for blueprint to create service account 'twinbox-automation' (${attempt}/${attempts})"
    sleep 5
    attempt=$((attempt + 1))
  done

  fail "Blueprint service account 'twinbox-automation' did not appear within expected time"
}

wait_for_blueprint_service_account

# Clean up the port-forward from the wait function.
if [[ -n "${AUTHENTIK_FORWARD_PID:-}" ]]; then
  kill "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
  wait "$AUTHENTIK_FORWARD_PID" >/dev/null 2>&1 || true
fi
rm -f "${AUTHENTIK_FORWARD_LOG:-}"

# Create default OAuth2 provider flows if they don't exist
log "Ensuring default OAuth2 provider flows exist"

AUTHENTIK_LOCAL_FORWARD_PORT="${AUTHENTIK_LOCAL_FORWARD_PORT:-18299}"
authentik_ensure_token
authentik_setup_forward

ensure_embedded_outpost_browser_host

authentik_ensure_default_provider_flows

log "Authentik installation complete"
