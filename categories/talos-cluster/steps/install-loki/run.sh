#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"
export KUBECONFIG="$KUBECONFIG_FILE"

manifest_path="$WORKSPACE_ROOT/gitops/apps/loki.yaml"
rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/loki-application-XXXXXX")"
trap 'rm -f "$rendered_manifest"' EXIT

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
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
loki_host="https://loki.${public_zone_name}"
loki_application_slug="loki"

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

  existing_pk="$(find_proxy_provider_pk_by_name "Loki")"
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

  existing_json="$(find_application_json_by_slug "$loki_application_slug")"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/core/applications/${loki_application_slug}/" "$application_payload" >/dev/null
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
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$openid_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for openid"
[[ -n "$email_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for email"
[[ -n "$profile_mapping_id" ]] || fail "Could not resolve Authentik scope mapping ID for profile"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

provider_payload="$(
  jq -n \
    --arg name "Loki" \
    --arg external_host "$loki_host" \
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

log "Provisioning Authentik proxy application for Loki"
provider_pk="$(create_or_update_proxy_provider "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a proxy provider ID for Loki"

application_payload="$(
  jq -n \
    --arg name "Loki" \
    --arg slug "$loki_application_slug" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "$loki_host" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for Loki"

application_json="$(find_application_json_by_slug "$loki_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for Loki"

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying Loki GitOps application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$rendered_manifest"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$rendered_manifest" \
  --application "loki" \
  --destination-namespace "monitoring"
