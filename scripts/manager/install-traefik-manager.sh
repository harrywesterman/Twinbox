#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

platform_dir="$WORKSPACE_ROOT/gitops/platform-apps/traefik-manager"
rendered_deployment="$(mktemp "${TMPDIR:-/tmp}/traefik-manager-deployment-XXXXXX")"
rendered_ingressroute="$(mktemp "${TMPDIR:-/tmp}/traefik-manager-ingressroute-XXXXXX")"
rendered_callback_ingressroute="$(mktemp "${TMPDIR:-/tmp}/traefik-manager-authentik-callback-XXXXXX")"
trap 'rm -f "$rendered_deployment" "$rendered_ingressroute" "$rendered_callback_ingressroute"' EXIT

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_slug" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine cluster slug from STEP_CONTEXT_JSON" >&2
  exit 1
}
[[ -n "$cluster_dns_domain" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine cluster DNS domain from STEP_CONTEXT_JSON" >&2
  exit 1
}

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine public zone name" >&2
  exit 1
}

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"
traefik_manager_host="https://traefik-manager.${public_zone_name}"
traefik_manager_application_slug="traefik-manager"

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
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_proxy_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  api_write POST "/providers/proxy/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug")"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
}

ensure_group_binding() {
  local target_uuid="$1"
  local group_id="$2"
  local binding_payload existing_pk

  binding_payload="$(
    jq -n \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
  )"

  existing_pk="$(
    api_get "/policies/bindings/?page_size=200" | jq -r \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '.results[]?
        | select((.target // "") == $target_uuid and (.group // "") == $group_id)
        | .pk // .id // empty' | head -n1
  )"
  if [[ -n "$existing_pk" ]]; then
    api_write PATCH "/policies/bindings/${existing_pk}/" "$binding_payload" >/dev/null
    return 0
  fi

  api_write POST "/policies/bindings/" "$binding_payload" >/dev/null
}

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not resolve Authentik authorization flow ID" >&2
  exit 1
}
[[ -n "$invalidation_flow_id" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not resolve Authentik invalidation flow ID" >&2
  exit 1
}
[[ -n "$admins_group_id" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not resolve Authentik admins group ID" >&2
  exit 1
}

provider_payload="$(
  jq -n \
    --arg name "Traefik Manager" \
    --arg external_host "$traefik_manager_host" \
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik proxy application for Traefik Manager"
provider_pk="$(create_or_update_proxy_provider "Traefik Manager" "$provider_payload")"
[[ -n "$provider_pk" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Authentik did not return a proxy provider ID for Traefik Manager" >&2
  exit 1
}

application_payload="$(
  jq -n \
    --arg name "Traefik Manager" \
    --arg slug "$traefik_manager_application_slug" \
    --arg provider_pk "$provider_pk" \
    --arg launch_url "$traefik_manager_host" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"
application_pk="$(create_or_update_application "$traefik_manager_application_slug" "$application_payload")"
[[ -n "$application_pk" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Authentik did not return an application ID for Traefik Manager" >&2
  exit 1
}

application_json="$(find_application_json_by_slug "$traefik_manager_application_slug")"
application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
[[ -n "$application_uuid" ]] || {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not determine Authentik application UUID for Traefik Manager" >&2
  exit 1
}
ensure_group_binding "$application_uuid" "$admins_group_id"

kubectl apply -f "$platform_dir/namespace.yaml"
kubectl apply -f "$platform_dir/serviceaccount.yaml"
kubectl apply -f "$platform_dir/pvc.yaml"
kubectl apply -f "$platform_dir/service.yaml"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$platform_dir/deployment.yaml" >"$rendered_deployment"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$platform_dir/ingressroute.yaml" >"$rendered_ingressroute"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$platform_dir/authentik-callback-ingressroute.yaml" >"$rendered_callback_ingressroute"
kubectl apply -f "$rendered_deployment"
kubectl apply -f "$rendered_ingressroute"
kubectl apply -f "$rendered_callback_ingressroute"
