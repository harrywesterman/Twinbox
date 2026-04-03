#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
BOOTSTRAP_ROOT="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
authentik_secret_file="$BOOTSTRAP_ROOT/secrets/global/authentik.json"
manifest_path="$WORKSPACE_ROOT/gitops/apps/authentik.yaml"
authentik_externalsecret_manifest="$WORKSPACE_ROOT/gitops/platform/authentik/externalsecret.yaml"
authentik_ingressroute_manifest="$WORKSPACE_ROOT/gitops/platform/authentik/ingressroute.yaml"

mkdir -p "$(dirname "$authentik_secret_file")"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
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
authentik_postgresql_host=""
authentik_postgresql_port=""
authentik_postgresql_name=""
authentik_postgresql_user=""
authentik_postgresql_password=""
authentik_postgresql_disable_server_side_cursors=""
authentik_postgresql_conn_max_age=""

if [[ -f "$authentik_secret_file" ]]; then
  authentik_secret_key="$(jq -r '."AUTHENTIK_SECRET_KEY" // empty' "$authentik_secret_file")"
  authentik_bootstrap_password="$(jq -r '."AUTHENTIK_BOOTSTRAP_PASSWORD" // empty' "$authentik_secret_file")"
  authentik_bootstrap_token="$(jq -r '."AUTHENTIK_BOOTSTRAP_TOKEN" // empty' "$authentik_secret_file")"
  authentik_bootstrap_email="$(jq -r '."AUTHENTIK_BOOTSTRAP_EMAIL" // empty' "$authentik_secret_file")"
  authentik_postgresql_host="$(jq -r '."AUTHENTIK_POSTGRESQL__HOST" // empty' "$authentik_secret_file")"
  authentik_postgresql_port="$(jq -r '."AUTHENTIK_POSTGRESQL__PORT" // empty' "$authentik_secret_file")"
  authentik_postgresql_name="$(jq -r '."AUTHENTIK_POSTGRESQL__NAME" // empty' "$authentik_secret_file")"
  authentik_postgresql_user="$(jq -r '."AUTHENTIK_POSTGRESQL__USER" // ."AUTHENTIK_POSTGRESQL__USERNAME" // empty' "$authentik_secret_file")"
  authentik_postgresql_password="$(jq -r '."AUTHENTIK_POSTGRESQL__PASSWORD" // empty' "$authentik_secret_file")"
  authentik_postgresql_disable_server_side_cursors="$(jq -r '."AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS" // empty' "$authentik_secret_file")"
  authentik_postgresql_conn_max_age="$(jq -r '."AUTHENTIK_POSTGRESQL__CONN_MAX_AGE" // empty' "$authentik_secret_file")"
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

tmp_file="$(mktemp)"
jq -n \
  --arg authentik_secret_key "$authentik_secret_key" \
  --arg authentik_bootstrap_password "$authentik_bootstrap_password" \
  --arg authentik_bootstrap_token "$authentik_bootstrap_token" \
  --arg authentik_bootstrap_email "$authentik_bootstrap_email" \
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
  }' >"$tmp_file"
install -m 600 "$tmp_file" "$authentik_secret_file"
rm -f "$tmp_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "authentik" \
  --json-file "$authentik_secret_file" \
  --required-keys "AUTHENTIK_SECRET_KEY,AUTHENTIK_BOOTSTRAP_PASSWORD,AUTHENTIK_BOOTSTRAP_TOKEN,AUTHENTIK_BOOTSTRAP_EMAIL,AUTHENTIK_HOST,AUTHENTIK_HOST_BROWSER,AUTHENTIK_POSTGRESQL__HOST,AUTHENTIK_POSTGRESQL__PORT,AUTHENTIK_POSTGRESQL__NAME,AUTHENTIK_POSTGRESQL__USER,AUTHENTIK_POSTGRESQL__USERNAME,AUTHENTIK_POSTGRESQL__PASSWORD,AUTHENTIK_POSTGRESQL__DISABLE_SERVER_SIDE_CURSORS,AUTHENTIK_POSTGRESQL__CONN_MAX_AGE"

export KUBECONFIG="$KUBECONFIG_FILE"

kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$authentik_externalsecret_manifest"
kubectl apply -f "$authentik_ingressroute_manifest"

for _attempt in $(seq 1 60); do
  if kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1 || fail "authentik-bootstrap secret did not appear after applying the ExternalSecret"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$manifest_path" \
  --application "authentik" \
  --no-wait

for deployment in authentik-server authentik-worker; do
  for _attempt in $(seq 1 60); do
    if kubectl -n authentik get deployment "$deployment" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  kubectl -n authentik get deployment "$deployment" >/dev/null 2>&1 || fail "deployment/${deployment} did not appear after applying Authentik"
done
