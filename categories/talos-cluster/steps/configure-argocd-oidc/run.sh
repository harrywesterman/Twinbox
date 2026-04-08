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

if [[ -z "$AUTHENTIK_HOST" ]]; then
  AUTHENTIK_HOST="https://authentik.${public_zone_name}"
fi

argocd_host="https://argocd.${public_zone_name}"
argocd_redirect_uri="${argocd_host}/auth/callback"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

tf_workdir="$MANAGER_DATA_DIR/opentofu/authentik-argocd-${cluster_id}"
mkdir -p "$tf_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-argocd/"* "$tf_workdir/"

cat >"$tf_workdir/terraform.tfvars" <<EOF
application_name = "Argo CD"
application_slug = "argocd"
authentik_url = "${AUTHENTIK_HOST}"
argocd_redirect_uri = "${argocd_redirect_uri}"
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Argo CD"
cd "$tf_workdir"
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu init -no-color -input=false
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu apply -no-color -auto-approve -input=false

argocd_client_id="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw client_id)"
argocd_client_secret="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw client_secret)"
argocd_issuer_url="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw issuer_url)"

argocd_secret_file="$secrets_dir/argocd-oidc-${cluster_id}.json"
cat >"$argocd_secret_file" <<EOF
{
  "ARGOCD_OIDC_CLIENT_ID": "$argocd_client_id",
  "ARGOCD_OIDC_CLIENT_SECRET": "$argocd_client_secret",
  "ARGOCD_OIDC_ISSUER_URL": "$argocd_issuer_url",
  "ARGOCD_REDIRECT_URI": "$argocd_redirect_uri",
  "ARGOCD_HOST": "$argocd_host",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$argocd_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "argocd-oidc" \
  --json-file "$argocd_secret_file" \
  --required-keys "ARGOCD_OIDC_CLIENT_ID,ARGOCD_OIDC_CLIENT_SECRET,ARGOCD_OIDC_ISSUER_URL,ARGOCD_REDIRECT_URI,ARGOCD_HOST"
rm -f "$argocd_secret_file"

kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/argocd/externalsecret.yaml"
kubectl -n argocd wait --for=condition=Ready externalsecret/argocd-oidc --timeout=10m

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshing platform-ingress so Argo CD picks up OIDC config"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml" \
  --application "platform-ingress" \
  --destination-namespace "argocd"

if kubectl -n argocd get deployment/argocd-server >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting Argo CD server to load OIDC settings"
  kubectl -n argocd rollout restart deployment/argocd-server
  kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD Authentik configuration complete"
