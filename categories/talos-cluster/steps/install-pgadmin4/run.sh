#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

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
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

resolve_authentik_field() {
  local field="$1"
  local authentik_secret_json

  authentik_secret_json="$(openbao_read_global_secret_json authentik)"
  jq -r --arg field "$field" '.[$field] // empty' <<<"$authentik_secret_json"
}

resolve_authentik_db_password() {
  kubectl -n databases get secret authentik-db-credentials -o jsonpath='{.data.password}' | base64 -d
}

wait_for_secret() {
  local namespace="$1"
  local secret_name="$2"
  local timeout_seconds="${3:-600}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Timed out waiting for secret ${namespace}/${secret_name}"
}

wait_for_deployment() {
  local namespace="$1"
  local deployment_name="$2"
  local timeout_seconds="${3:-600}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if kubectl -n "$namespace" get deployment "$deployment_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Timed out waiting for deployment ${namespace}/${deployment_name}"
}

resolve_ready_pod() {
  local namespace="$1"
  local selector="$2"

  kubectl -n "$namespace" get pods -l "$selector" -o json | jq -r '
    .items
    | map(select(
        any(.status.conditions[]?; .type == "Ready" and .status == "True")
      ))
    | sort_by(.metadata.creationTimestamp)
    | last
    | .metadata.name // empty
  '
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
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"

pgadmin_host="https://pgadmin4.${public_zone_name}"
pgadmin_redirect_uri="${pgadmin_host}/oauth2/authorize"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"
manifest_path="$WORKSPACE_ROOT/gitops/apps/platform-ingress.yaml"
rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/pgadmin4-application.XXXXXX.yaml")"
trap 'rm -f "$rendered_manifest"' EXIT
pgadmin_servers_file="$secrets_dir/pgadmin4-servers-${cluster_id}.json"
pgadmin_db_password_secret_name="pgadmin4-db-password"
pgadmin_application_slug="pgadmin4"
pgadmin_issuer_url="${AUTHENTIK_HOST%/}/application/o/${pgadmin_application_slug}/"
pgadmin_client_id="$(openssl rand -hex 16)"
pgadmin_client_secret="$(openssl rand -hex 24)"
authentik_oidc_state_key="authentik-pgadmin4"
pgadmin_default_email="pgadmin@${public_zone_name}"
pgadmin_default_password="$(openssl rand -hex 24)"
pgadmin_master_password="$(openssl rand -hex 32)"
pgadmin_authentik_db_password="$(resolve_authentik_db_password)"

existing_pgadmin_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_pgadmin_secret_json="$(openbao_read_global_secret_json pgadmin4-oidc 2>/dev/null || true)"
fi

if [[ -n "$existing_pgadmin_secret_json" ]]; then
  existing_client_id="$(jq -r '.PGADMIN_OAUTH2_CLIENT_ID // empty' <<<"$existing_pgadmin_secret_json")"
  existing_client_secret="$(jq -r '.PGADMIN_OAUTH2_CLIENT_SECRET // empty' <<<"$existing_pgadmin_secret_json")"
  existing_default_email="$(jq -r '.PGADMIN_DEFAULT_EMAIL // empty' <<<"$existing_pgadmin_secret_json")"
  existing_default_password="$(jq -r '.PGADMIN_DEFAULT_PASSWORD // empty' <<<"$existing_pgadmin_secret_json")"
  existing_master_password="$(jq -r '.PGADMIN_MASTER_PASSWORD // empty' <<<"$existing_pgadmin_secret_json")"

  if [[ -n "$existing_client_id" && -n "$existing_client_secret" ]]; then
    pgadmin_client_id="$existing_client_id"
    pgadmin_client_secret="$existing_client_secret"
  fi
  if [[ -n "$existing_default_email" ]]; then
    pgadmin_default_email="$existing_default_email"
  fi
  if [[ -n "$existing_default_password" ]]; then
    pgadmin_default_password="$existing_default_password"
  fi
  if [[ -n "$existing_master_password" ]]; then
    pgadmin_master_password="$existing_master_password"
  fi
fi

if [[ "$pgadmin_default_email" == *".twinbox.local" ]]; then
  pgadmin_default_email="pgadmin@${public_zone_name}"
fi

find_oauth2_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/oauth2/?page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  authentik_api_get "/core/applications/${application_slug}/" 2>/dev/null || true
}

find_policy_binding_pk() {
  local target_uuid="$1"
  local group_id="$2"
  local response

  response="$(authentik_api_get "/policies/bindings/?page_size=200")"
  jq -r \
    --arg target_uuid "$target_uuid" \
    --arg group_id "$group_id" \
    '.results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // empty' <<<"$response" | head -n1
}

create_or_update_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_oauth2_provider_pk_by_name "pgAdmin 4")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/oauth2/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/oauth2/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_payload="$1"
  local existing_json existing_pk response_file http_status

  existing_json="$(find_application_json_by_slug "$pgadmin_application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${pgadmin_application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  response_file="$(mktemp)"
  http_status="$(
    curl -sS \
      -X POST \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      --data "$application_payload" \
      -o "$response_file" \
      -w '%{http_code}' \
      "${AUTHENTIK_API_BASE}/core/applications/"
  )" || http_status="000"

  if [[ "$http_status" =~ ^2 ]]; then
    jq -r '.pk // .id // empty' <"$response_file"
    rm -f "$response_file"
    return 0
  fi

  existing_json="$(find_application_json_by_slug "$pgadmin_application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose an application ID for pgAdmin 4"

  authentik_api_write PATCH "/core/applications/${pgadmin_application_slug}/" "$application_payload" >/dev/null
  rm -f "$response_file"
  printf '%s\n' "$existing_pk"
}

ensure_group_binding() {
  local target_uuid="$1"
  local group_id="$2"
  local binding_payload existing_pk

  binding_payload="$(
    jq -n \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '{target: $target_uuid, group: $group_id, order: 1}'
  )"

  existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  authentik_api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(authentik_resolve_scope_mapping_id "openid")"
email_mapping_id="$(authentik_resolve_scope_mapping_id "email")"
profile_mapping_id="$(authentik_resolve_scope_mapping_id "profile")"
admins_group_id="$(authentik_find_group_id "admins")"
signing_key_id="$(authentik_resolve_signing_key_id)"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "pgAdmin 4" \
    --arg client_id "$pgadmin_client_id" \
    --arg client_secret "$pgadmin_client_secret" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    --arg signing_key "$signing_key_id" \
    --arg redirect_uri "$pgadmin_redirect_uri" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      client_id: $client_id,
      client_secret: $client_secret,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      signing_key: $signing_key,
      redirect_uris: [
        {
          matching_mode: "strict",
          url: $redirect_uri
        }
      ],
      property_mappings: $property_mappings,
      include_claims_in_id_token: true,
      client_type: "confidential",
      issuer_mode: "per_provider"
    }'
)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik OIDC client for pgAdmin 4"
provider_pk="$(create_or_update_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for pgAdmin 4"

application_payload="$(
  jq -n \
    --arg name "pgAdmin 4" \
    --arg slug "$pgadmin_application_slug" \
    --arg launch_url "$pgadmin_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for pgAdmin 4"

application_json="$(find_application_json_by_slug "$pgadmin_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for pgAdmin 4"
ensure_group_binding "$application_uuid" "$admins_group_id"

pgadmin_secret_file="$secrets_dir/pgadmin4-oidc-${cluster_id}.json"
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
rm -f "$pgadmin_secret_file"

kubectl create namespace pgadmin4 --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating pgAdmin 4 database password secret"
kubectl -n pgadmin4 create secret generic "$pgadmin_db_password_secret_name" \
  --from-literal=PGADMIN_AUTHENTIK_DB_PASSWORD="$pgadmin_authentik_db_password" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying pgAdmin 4 ExternalSecret"
kubectl apply -f "$WORKSPACE_ROOT/gitops/platform/pgadmin4/externalsecret.yaml"
kubectl -n pgadmin4 wait --for=condition=Ready externalsecret/pgadmin4-oidc --timeout=10m
wait_for_secret pgadmin4 pgadmin4-bootstrap

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying shared platform-ingress Argo CD application"
kubectl delete application pgadmin4 -n argocd --ignore-not-found=true >/dev/null 2>&1 || true
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$rendered_manifest"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_manifest" \
  --application "platform-ingress" \
  --destination-namespace "argocd" \
  --no-wait

wait_for_deployment pgadmin4 pgadmin4
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting pgAdmin 4 to pick up secret-backed env vars"
kubectl -n pgadmin4 rollout restart deploy/pgadmin4
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for pgAdmin 4 pod readiness"
kubectl -n pgadmin4 wait --for=condition=Ready pod -l app.kubernetes.io/name=pgadmin4 --timeout=10m
pgadmin_pod="$(resolve_ready_pod pgadmin4 app.kubernetes.io/name=pgadmin4)"
[[ -n "$pgadmin_pod" ]] || fail "Could not resolve a ready pgAdmin 4 pod after restart"
sleep 5
kubectl -n pgadmin4 wait --for=condition=Ready "pod/$pgadmin_pod" --timeout=10m

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading pgAdmin 4 shared server entry"
jq -n \
  --arg server_name "Authentik Database" \
  --arg server_group "Shared Servers" \
  --arg server_host "authentik-db-pooler-rw-session.databases.svc.cluster.local" \
  --argjson server_port 5432 \
  --arg maintenance_db "postgres" \
  --arg username "authentik" \
  --arg shared_username "authentik" \
  --arg password_exec_cmd 'printf %s "$PGADMIN_AUTHENTIK_DB_PASSWORD"' \
  '{
    Servers: {
      "1": {
        Name: $server_name,
        Group: $server_group,
        Host: $server_host,
        Port: $server_port,
        MaintenanceDB: $maintenance_db,
        Username: $username,
        SharedUsername: $shared_username,
        PasswordExecCommand: $password_exec_cmd,
        Shared: true,
        ConnectionParameters: {
          sslmode: "prefer"
        },
        Comment: "CloudNativePG pooler for the Authentik cluster"
      }
    }
  }' >"$pgadmin_servers_file"

kubectl -n pgadmin4 exec -i "pod/$pgadmin_pod" -c pgadmin4 -- /bin/sh -ec \
  "cat >/tmp/pgadmin4-servers.json && /venv/bin/python /pgadmin4/setup.py load-servers /tmp/pgadmin4-servers.json --user ${pgadmin_default_email} --sqlite-path /var/lib/pgadmin/pgadmin4.db --replace" \
  <"$pgadmin_servers_file"
rm -f "$pgadmin_servers_file"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] pgAdmin 4 Authentik configuration complete"
