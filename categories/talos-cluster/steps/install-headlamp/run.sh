#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

authentik_ensure_token

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"

headlamp_host="https://headlamp.${public_zone_name}"
headlamp_redirect_uri="${headlamp_host}/oidc-callback"

tf_workdir="$MANAGER_DATA_DIR/opentofu/authentik-headlamp-${cluster_id}"
mkdir -p "$tf_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-headlamp/"* "$tf_workdir/"

cat >"$tf_workdir/terraform.tfvars" <<EOF
application_name = "Headlamp"
application_slug = "headlamp"
authentik_url = "${AUTHENTIK_HOST}"
headlamp_redirect_uri = "${headlamp_redirect_uri}"
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Headlamp"
cd "$tf_workdir"
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu init -no-color -input=false
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu apply -no-color -auto-approve -input=false

headlamp_client_id="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw client_id)"
headlamp_client_secret="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw client_secret)"
headlamp_issuer_url="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw issuer_url)"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

headlamp_secret_file="$secrets_dir/headlamp-oidc-${cluster_id}.json"
cat >"$headlamp_secret_file" <<EOF
{
  "OIDC_CLIENT_ID": "$headlamp_client_id",
  "OIDC_CLIENT_SECRET": "$headlamp_client_secret",
  "OIDC_ISSUER_URL": "$headlamp_issuer_url",
  "OIDC_SCOPES": "openid profile email",
  "HEADLAMP_CONFIG_OIDC_CLIENT_ID": "$headlamp_client_id",
  "HEADLAMP_CONFIG_OIDC_CLIENT_SECRET": "$headlamp_client_secret",
  "HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL": "$headlamp_issuer_url",
  "HEADLAMP_CONFIG_OIDC_SCOPES": "openid profile email",
  "CLUSTER_ID": "$cluster_id",
  "HEADLAMP_HOST": "$headlamp_host"
}
EOF

chmod 600 "$headlamp_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "headlamp-oidc" \
  --json-file "$headlamp_secret_file" \
  --required-keys "OIDC_CLIENT_ID,OIDC_CLIENT_SECRET,OIDC_ISSUER_URL,OIDC_SCOPES,HEADLAMP_CONFIG_OIDC_CLIENT_ID,HEADLAMP_CONFIG_OIDC_CLIENT_SECRET,HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL,HEADLAMP_CONFIG_OIDC_SCOPES"
rm -f "$headlamp_secret_file"

if command -v kubectl &>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Headlamp ExternalSecret"
  kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/headlamp/externalsecret.yaml"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Headlamp Argo CD application"
  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$WORKSPACE_ROOT/gitops/apps/headlamp.yaml" \
    --application "headlamp"

  if kubectl -n kube-system get deployment/headlamp >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting Headlamp to pick up Authentik OIDC settings"
    kubectl -n kube-system rollout restart deployment/headlamp
    kubectl -n kube-system rollout status deployment/headlamp --timeout=10m
  fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Headlamp Authentik configuration complete"
