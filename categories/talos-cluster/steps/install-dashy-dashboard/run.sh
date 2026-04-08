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

dashy_host="https://start.${public_zone_name}"
dashy_redirect_uri="${dashy_host}"

tf_workdir="$MANAGER_DATA_DIR/opentofu/authentik-dashy-${cluster_id}"
mkdir -p "$tf_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-dashy/"* "$tf_workdir/"

cat >"$tf_workdir/terraform.tfvars" <<EOF
application_name = "Dashy"
application_slug = "dashy"
authentik_url = "${AUTHENTIK_HOST}"
dashy_redirect_uri = "${dashy_redirect_uri}"
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for Dashy"
cd "$tf_workdir"
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu init -no-color -input=false
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu apply -no-color -auto-approve -input=false

dashy_client_id="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw client_id)"
dashy_issuer_url="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -raw issuer_url)"

secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

dashy_secret_file="$secrets_dir/dashy-oidc-${cluster_id}.json"
cat >"$dashy_secret_file" <<EOF
{
  "DASHY_OIDC_CLIENT_ID": "$dashy_client_id",
  "DASHY_OIDC_ENDPOINT": "$dashy_issuer_url",
  "DASHY_OIDC_SCOPE": "openid profile email",
  "CLUSTER_ID": "$cluster_id",
  "DASHY_HOST": "$dashy_host"
}
EOF

chmod 600 "$dashy_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "dashy-oidc" \
  --json-file "$dashy_secret_file" \
  --required-keys "DASHY_OIDC_CLIENT_ID,DASHY_OIDC_ENDPOINT,DASHY_OIDC_SCOPE"
rm -f "$dashy_secret_file"

kubectl create namespace dashy --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Dashy ExternalSecret"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/dashy/externalsecret.yaml"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Dashy OIDC secret"
kubectl -n dashy wait --for=condition=Ready externalsecret/dashy-oidc --timeout=10m

for attempt in $(seq 1 120); do
  if kubectl -n dashy get deployment/dashy >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    fail "Dashy deployment did not appear in time"
  fi
  sleep 5
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting Dashy to pick up Authentik OIDC settings"
kubectl -n dashy rollout restart deployment/dashy
kubectl -n dashy rollout status deployment/dashy --timeout=10m

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dashy Authentik configuration complete"
