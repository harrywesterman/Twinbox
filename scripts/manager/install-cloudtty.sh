#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  local attempts=120
  local attempt=1

  while true; do
    if kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout=15s >/dev/null 2>&1; then
      log "Deployment/${deployment} is ready"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for Deployment/${deployment}"
    fi

    log "Waiting for Deployment/${deployment}"
    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_cloudshell() {
  local namespace="$1"
  local name="$2"
  local attempts=120
  local attempt=1

  while true; do
    local phase=""
    local url=""
    phase="$(kubectl -n "$namespace" get cloudshell "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    url="$(kubectl -n "$namespace" get cloudshell "$name" -o jsonpath='{.status.accessUrl}' 2>/dev/null || true)"
    if [[ "$phase" == "Ready" && -n "$url" ]]; then
      log "CloudShell/${name} is ready at ${url}"
      printf '%s\n' "$url"
      return 0
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "Timed out waiting for CloudShell/${name}"
    fi

    log "Waiting for CloudShell/${name}"
    sleep 5
    attempt=$((attempt + 1))
  done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
[[ -n "${STEP_CONTEXT_JSON:-}" ]] || fail "STEP_CONTEXT_JSON is required"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v helm >/dev/null 2>&1 || fail "helm not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

export KUBECONFIG="$KUBECONFIG_FILE"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

NAMESPACE="${CLOUDTTY_NAMESPACE:-cloudtty-system}"
RELEASE_NAME="${CLOUDTTY_RELEASE_NAME:-cloudtty-operator}"
CHART_NAME="${CLOUDTTY_CHART_NAME:-cloudtty/cloudtty}"
CLOUDSHELL_NAME="${CLOUDTTY_CLOUDSHELL_NAME:-cloudtty-shell}"
CONTROLLER_DEPLOYMENT_NAME="${RELEASE_NAME}-controller-manager"
PLATFORM_DIR="$WORKSPACE_ROOT/gitops/platform-apps/cloudtty"

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"
[[ -n "$cluster_slug" ]] || fail "Could not determine cluster slug from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"
rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/cloudtty-ingressroute-XXXXXX.yaml")"
trap 'rm -f "$rendered_ingressroute"' EXIT

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
cloudtty_host="https://cloudtty.${public_zone_name}"
cloudtty_application_slug="cloudtty"

api_get() {
  local path="$1"
  curl -fsS \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -H "Accept: application/json" \
    "${AUTHENTIK_API_BASE}${path}"
}

api_write() {
  local method="$1"
  local path="$2"
  local payload="$3"
  curl -fsS \
    -X "$method" \
    -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${AUTHENTIK_API_BASE}${path}"
}

find_proxy_provider_pk_by_name() {
  local provider_name="$1"

  api_get "/providers/proxy/?page_size=100" | jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  api_get "/core/applications/${application_slug}/" 2>/dev/null || true
}

create_or_update_proxy_provider() {
  local provider_payload="$1"
  local existing_pk

  existing_pk="$(find_proxy_provider_pk_by_name "Cloudtty")"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  api_write POST "/providers/proxy/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_payload="$1"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$cloudtty_application_slug")"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/core/applications/${cloudtty_application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

resolve_flow_id() {
  local slug="$1"
  local designation="$2"
  authentik_resolve_flow_id "$slug" "$designation"
}

resolve_scope_mapping_id() {
  local scope_name="$1"
  authentik_resolve_scope_mapping_id "$scope_name"
}

authorization_flow_id="$(resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
openid_mapping_id="$(resolve_scope_mapping_id "openid")"
email_mapping_id="$(resolve_scope_mapping_id "email")"
profile_mapping_id="$(resolve_scope_mapping_id "profile")"
signing_key_id="$(authentik_resolve_signing_key_id)"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$signing_key_id" ]] || fail "Could not resolve Authentik signing key ID for ${AUTHENTIK_SIGNING_KEY_NAME}"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

property_mapping_ids_json="$(
  jq -cn \
    --arg openid "$openid_mapping_id" \
    --arg email "$email_mapping_id" \
    --arg profile "$profile_mapping_id" \
    '[$openid, $email, $profile]'
)"

provider_payload="$(
  jq -n \
    --arg name "Cloudtty" \
    --arg external_host "$cloudtty_host" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    '{
      name: $name,
      external_host: $external_host,
      authorization_flow: $authorization_flow,
      invalidation_flow: $invalidation_flow,
      mode: "forward_single"
    }'
)"

log "Provisioning Authentik proxy application for Cloudtty"
provider_pk="$(create_or_update_proxy_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a proxy provider ID for Cloudtty"

application_payload="$(
  jq -n \
    --arg name "Cloudtty" \
    --arg slug "$cloudtty_application_slug" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "$cloudtty_host" \
    --argjson property_mappings "$property_mapping_ids_json" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Cloudtty"

application_json="$(find_application_json_by_slug "$cloudtty_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Cloudtty"

binding_payload="$(jq -n --arg target_uuid "$application_uuid" --arg group_id "$admins_group_id" '{target: $target_uuid, group: $group_id, order: 1, enabled: true}')"
existing_binding_pk="$(
  api_get "/policies/bindings/?page_size=200" | jq -r \
    --arg target_uuid "$application_uuid" \
    --arg group_id "$admins_group_id" \
    '.results[]?
      | select((.target // "") == $target_uuid and (.group // "") == $group_id)
      | .pk // .id // empty' | head -n1
)"
if [[ -n "$existing_binding_pk" ]]; then
  api_write PATCH "/policies/bindings/${existing_binding_pk}/" "$binding_payload" >/dev/null
else
  api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
fi

outpost_json="$(api_get "/outposts/instances/?page_size=100")"
outpost_id="$(printf '%s' "$outpost_json" | jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' | head -n1)"
[[ -n "$outpost_id" && "$outpost_id" != "null" ]] || fail "Could not find the embedded Authentik outpost"

current_providers="$(printf '%s' "$outpost_json" | jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []')"
updated_providers="$(
  printf '%s\n' "$current_providers" \
    | jq --arg provider_pk "$provider_pk" '
        . + [$provider_pk]
        | map(tostring)
        | unique
      '
)"

if [[ "$current_providers" != "$updated_providers" ]]; then
  api_write PATCH "/outposts/instances/${outpost_id}/" "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
fi

log "Adding cloudtty Helm repository"
if ! helm repo list 2>/dev/null | awk '$1 == "cloudtty" { found = 1 } END { exit found ? 0 : 1 }'; then
  helm repo add cloudtty https://cloudtty.github.io/cloudtty >/dev/null
fi
helm repo update >/dev/null

log "Installing cloudtty operator into ${NAMESPACE}"
helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
  --version "$PINNED_CLOUDTTY_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 10m

wait_for_deployment "$NAMESPACE" "$CONTROLLER_DEPLOYMENT_NAME"

log "Applying CloudShell resource"
kubectl apply -f - <<EOF
apiVersion: cloudshell.cloudtty.io/v1alpha1
kind: CloudShell
metadata:
  name: ${CLOUDSHELL_NAME}
  namespace: ${NAMESPACE}
spec:
  exposureMode: NodePort
  commandAction: bash
  once: false
EOF

cloudshell_url="$(wait_for_cloudshell "$NAMESPACE" "$CLOUDSHELL_NAME")"
kubectl apply -f "$PLATFORM_DIR/authentik-forwardauth-middleware.yaml"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$PLATFORM_DIR/ingressroute.yaml" >"$rendered_ingressroute"
kubectl apply -f "$rendered_ingressroute"
log "Cloudtty ready at ${cloudshell_url}"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg namespace "$NAMESPACE" \
    --arg release_name "$RELEASE_NAME" \
    --arg chart_name "$CHART_NAME" \
    --arg cloudshell_name "$CLOUDSHELL_NAME" \
    --arg controller_deployment_name "$CONTROLLER_DEPLOYMENT_NAME" \
    --arg access_url "$cloudshell_url" \
    --arg chart_version "$PINNED_CLOUDTTY_CHART_VERSION" \
    '{
      namespace: $namespace,
      release_name: $release_name,
      chart_name: $chart_name,
      chart_version: $chart_version,
      controller_deployment_name: $controller_deployment_name,
      cloudshell_name: $cloudshell_name,
      access_url: $access_url
    }' >"$STEP_RESULT_FILE"
fi
