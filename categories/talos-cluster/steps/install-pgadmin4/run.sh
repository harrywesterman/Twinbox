#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

resolve_kubeconfig_file() {
  local candidate=""

  if [[ -n "${KUBECONFIG_FILE:-}" && -f "${KUBECONFIG_FILE:-}" ]]; then
    printf '%s\n' "$KUBECONFIG_FILE"
    return 0
  fi

  for candidate in /home/twinbox/.kube/config "${HOME:-}/.kube/config"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  fail "Could not find a usable kubeconfig; expected cluster attachment or /home/twinbox/.kube/config"
}

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG="$KUBECONFIG_FILE"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

authentik_secret_file="/opt/twinbox/bootstrap/secrets/global/authentik.json"
[[ -f "$authentik_secret_file" ]] || fail "Authentik bootstrap secret not found at $authentik_secret_file"

authentik_host="$(jq -r '.AUTHENTIK_HOST // empty' "$authentik_secret_file")"
authentik_token="$(jq -r '.AUTHENTIK_BOOTSTRAP_TOKEN // empty' "$authentik_secret_file")"

if [[ -z "$authentik_host" ]]; then
  authentik_host="https://authentik.${public_zone_name}"
fi

[[ -n "$authentik_token" ]] || fail "Could not read AUTHENTIK_BOOTSTRAP_TOKEN from $authentik_secret_file"

pgadmin_host="https://pgadmin4.${public_zone_name}"
pgadmin_redirect_uri="${pgadmin_host}/oauth2/authorize"

tf_workdir="$MANAGER_DATA_DIR/opentofu/authentik-pgadmin4-${cluster_id}"
mkdir -p "$tf_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-pgadmin4/"* "$tf_workdir/"

cat >"$tf_workdir/terraform.tfvars" <<EOF
application_name = "pgAdmin 4"
application_slug = "pgadmin4"
authentik_url = "${authentik_host}"
pgadmin4_redirect_uri = "${pgadmin_redirect_uri}"
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for pgAdmin 4"
cd "$tf_workdir"
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu init -no-color -input=false
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu apply -no-color -auto-approve -input=false

pgadmin_client_id="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu output -no-color -raw client_id)"
pgadmin_client_secret="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu output -no-color -raw client_secret)"
pgadmin_issuer_url="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu output -no-color -raw issuer_url)"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

pgadmin_secret_file="$secrets_dir/pgadmin4-oidc-${cluster_id}.json"
pgadmin_default_email="pgadmin@${cluster_slug}.twinbox.local"
pgadmin_default_password="$(openssl rand -hex 24)"
pgadmin_master_password="$(openssl rand -hex 32)"
pgadmin_server_metadata_url="${pgadmin_issuer_url}.well-known/openid-configuration"

jq -n \
  --arg pgadmin_default_email "$pgadmin_default_email" \
  --arg pgadmin_default_password "$pgadmin_default_password" \
  --arg pgadmin_master_password "$pgadmin_master_password" \
  --arg pgadmin_oauth2_client_id "$pgadmin_client_id" \
  --arg pgadmin_oauth2_client_secret "$pgadmin_client_secret" \
  --arg pgadmin_oauth2_server_metadata_url "$pgadmin_server_metadata_url" \
  --arg pgadmin_oauth2_scope "openid email profile" \
  --arg pgadmin_host "$pgadmin_host" \
  --arg pgadmin_redirect_uri "$pgadmin_redirect_uri" \
  '{
    "PGADMIN_DEFAULT_EMAIL": $pgadmin_default_email,
    "PGADMIN_DEFAULT_PASSWORD": $pgadmin_default_password,
    "PGADMIN_MASTER_PASSWORD": $pgadmin_master_password,
    "PGADMIN_OAUTH2_CLIENT_ID": $pgadmin_oauth2_client_id,
    "PGADMIN_OAUTH2_CLIENT_SECRET": $pgadmin_oauth2_client_secret,
    "PGADMIN_OAUTH2_SERVER_METADATA_URL": $pgadmin_oauth2_server_metadata_url,
    "PGADMIN_OAUTH2_SCOPE": $pgadmin_oauth2_scope,
    "PGADMIN_HOST": $pgadmin_host,
    "PGADMIN_OAUTH2_REDIRECT_URI": $pgadmin_redirect_uri
  }' >"$pgadmin_secret_file"

chmod 600 "$pgadmin_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "pgadmin4-oidc" \
  --json-file "$pgadmin_secret_file" \
  --required-keys "PGADMIN_DEFAULT_EMAIL,PGADMIN_DEFAULT_PASSWORD,PGADMIN_MASTER_PASSWORD,PGADMIN_OAUTH2_CLIENT_ID,PGADMIN_OAUTH2_CLIENT_SECRET,PGADMIN_OAUTH2_SERVER_METADATA_URL,PGADMIN_OAUTH2_SCOPE"

kubectl create namespace pgadmin4 --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying pgAdmin 4 ExternalSecret"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/pgadmin4/externalsecret.yaml"
kubectl -n pgadmin4 wait --for=condition=Ready externalsecret/pgadmin4-oidc --timeout=10m

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying pgAdmin 4 Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/pgadmin4.yaml" \
  --application "pgadmin4" \
  --destination-namespace "pgadmin4"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] pgAdmin 4 Authentik configuration complete"
