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

  while true; do
    if status_json="$(kubectl -n authentik get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}"
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

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

wait_for_deployment_rollout "authentik-server" "Authentik server"
wait_for_deployment_rollout "authentik-worker" "Authentik worker"

authentik_ensure_token
authentik_setup_forward

AUTHENTIK_HOST="${AUTHENTIK_HOST:-https://authentik.${public_zone_name}}"

for attempt in $(seq 1 120); do
  if kubectl -n traefik get ingressroute/traefik-dashboard >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/longhorn >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/proxmox >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/twinboxwizard >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/seaweedfs >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/seaweedfs-admin >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 120 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: management console ingress routes did not appear in time" >&2
    exit 1
  fi
  sleep 5
done

find_proxy_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/proxy/?page_size=100")"
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

create_or_update_proxy_provider() {
  local provider_name="$1"
  local provider_payload="$2"
  local existing_pk

  existing_pk="$(find_proxy_provider_pk_by_name "$provider_name")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/providers/proxy/${existing_pk}/" "$provider_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/providers/proxy/" "$provider_payload" | jq -r '.pk // .id // empty'
}

create_or_update_application() {
  local application_slug="$1"
  local application_payload="$2"
  local existing_json existing_pk response

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  response="$(authentik_api_write POST "/core/applications/" "$application_payload")"
  if [[ -n "$response" ]]; then
    existing_pk="$(jq -r '.pk // .id // empty' <<<"$response")"
    if [[ -n "$existing_pk" ]]; then
      printf '%s\n' "$existing_pk"
      return 0
    fi
  fi

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  [[ -n "$existing_pk" ]] || fail "Authentik did not return or expose an application ID for ${application_slug}"

  authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
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
      '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
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
admins_group_id="$(authentik_find_group_id "admins")"

[[ -n "$authorization_flow_id" ]] || fail "Could not resolve Authentik authorization flow ID"
[[ -n "$invalidation_flow_id" ]] || fail "Could not resolve Authentik invalidation flow ID"
[[ -n "$admins_group_id" ]] || fail "Could not resolve Authentik admins group ID"

management_apps_json="$(
  jq -nc \
    --arg public_zone_name "$public_zone_name" \
    '[
      {
        key: "traefik_dashboard",
        name: "Traefik Dashboard",
        slug: "traefik-dashboard",
        external_host: "https://traefik.\($public_zone_name)",
        launch_url: "https://traefik.\($public_zone_name)/dashboard/"
      },
      {
        key: "longhorn",
        name: "Longhorn",
        slug: "longhorn",
        external_host: "https://longhorn.\($public_zone_name)",
        launch_url: "https://longhorn.\($public_zone_name)"
      },
      {
        key: "hubble",
        name: "Hubble",
        slug: "hubble",
        external_host: "https://hubble.\($public_zone_name)",
        launch_url: "https://hubble.\($public_zone_name)"
      },
      {
        key: "proxmox",
        name: "Proxmox",
        slug: "proxmox",
        external_host: "https://proxmox.\($public_zone_name)",
        launch_url: "https://proxmox.\($public_zone_name)"
      },
      {
        key: "twinboxwizard",
        name: "Twinbox Wizard",
        slug: "twinboxwizard",
        external_host: "https://twinboxwizard.\($public_zone_name)",
        launch_url: "https://twinboxwizard.\($public_zone_name)"
      },
      {
        key: "seaweedfs",
        name: "SeaweedFS",
        slug: "seaweedfs",
        external_host: "https://seaweedfs.\($public_zone_name)",
        launch_url: "https://seaweedfs.\($public_zone_name)"
      },
      {
        key: "seaweedfs_admin",
        name: "SeaweedFS Admin",
        slug: "seaweedfs-admin",
        external_host: "https://seaweedfs-admin.\($public_zone_name)",
        launch_url: "https://seaweedfs-admin.\($public_zone_name)"
      }
    ]'
)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik proxy applications for Traefik, Longhorn, Hubble, Proxmox, Twinbox Wizard, and SeaweedFS"

provider_ids_json='{}'
while IFS= read -r app_json; do
  app_key="$(jq -r '.key' <<<"$app_json")"
  app_name="$(jq -r '.name' <<<"$app_json")"
  app_slug="$(jq -r '.slug' <<<"$app_json")"
  app_external_host="$(jq -r '.external_host' <<<"$app_json")"
  app_launch_url="$(jq -r '.launch_url' <<<"$app_json")"

  provider_payload="$(
    jq -n \
      --arg name "$app_name" \
      --arg external_host "$app_external_host" \
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
  provider_pk="$(create_or_update_proxy_provider "$app_name" "$provider_payload")"
  [[ -n "$provider_pk" ]] || fail "Authentik did not return a proxy provider ID for ${app_name}"

  application_payload="$(
    jq -n \
      --arg name "$app_name" \
      --arg slug "$app_slug" \
      --arg launch_url "$app_launch_url" \
      --arg provider_pk "$provider_pk" \
      '{
        name: $name,
        slug: $slug,
        meta_launch_url: $launch_url,
        provider: ($provider_pk | tonumber)
      }'
  )"
  application_pk="$(create_or_update_application "$app_slug" "$application_payload")"
  [[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for ${app_name}"

  application_json="$(find_application_json_by_slug "$app_slug")"
  application_uuid="$(jq -r '.pk // .uuid // .id // empty' <<<"$application_json")"
  [[ -n "$application_uuid" ]] || fail "Could not determine Authentik application UUID for ${app_name}"
  ensure_group_binding "$application_uuid" "$admins_group_id"

  provider_ids_json="$(jq -c --arg app_key "$app_key" --arg provider_pk "$provider_pk" '. + {($app_key): $provider_pk}' <<<"$provider_ids_json")"
done < <(jq -c '.[]' <<<"$management_apps_json")

traefik_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.traefik_dashboard')"
longhorn_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.longhorn')"
hubble_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.hubble')"
proxmox_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.proxmox')"
twinboxwizard_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.twinboxwizard')"
seaweedfs_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.seaweedfs')"
seaweedfs_admin_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.seaweedfs_admin')"

[[ "$traefik_provider_id" != "null" && -n "$traefik_provider_id" ]] || fail "Could not determine Traefik provider ID"
[[ "$longhorn_provider_id" != "null" && -n "$longhorn_provider_id" ]] || fail "Could not determine Longhorn provider ID"
[[ "$hubble_provider_id" != "null" && -n "$hubble_provider_id" ]] || fail "Could not determine Hubble provider ID"
[[ "$proxmox_provider_id" != "null" && -n "$proxmox_provider_id" ]] || fail "Could not determine Proxmox provider ID"
[[ "$twinboxwizard_provider_id" != "null" && -n "$twinboxwizard_provider_id" ]] || fail "Could not determine Twinbox Wizard provider ID"
[[ "$seaweedfs_provider_id" != "null" && -n "$seaweedfs_provider_id" ]] || fail "Could not determine SeaweedFS provider ID"
[[ "$seaweedfs_admin_provider_id" != "null" && -n "$seaweedfs_admin_provider_id" ]] || fail "Could not determine SeaweedFS admin provider ID"

outpost_json="$(authentik_api_get "/outposts/instances/?page_size=100")"
outpost_id="$(printf '%s' "$outpost_json" | jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' | head -n1)"
[[ -n "$outpost_id" && "$outpost_id" != "null" ]] || fail "Could not find the embedded Authentik outpost"

current_providers="$(printf '%s' "$outpost_json" | jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []')"
updated_providers="$(
  printf '%s\n' "$current_providers" \
    | jq --arg traefik "$traefik_provider_id" --arg longhorn "$longhorn_provider_id" --arg hubble "$hubble_provider_id" --arg proxmox "$proxmox_provider_id" --arg twinboxwizard "$twinboxwizard_provider_id" --arg seaweedfs "$seaweedfs_provider_id" --arg seaweedfs_admin "$seaweedfs_admin_provider_id" '
        . + [$traefik, $longhorn, $hubble, $proxmox, $twinboxwizard]
        + [$seaweedfs, $seaweedfs_admin]
        | map(tostring)
        | unique
      '
)"

if [[ "$current_providers" != "$updated_providers" ]]; then
  authentik_api_write PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
fi

final_outpost_json="$(authentik_api_get "/outposts/instances/${outpost_id}/")"
final_provider_count="$(printf '%s' "$final_outpost_json" | jq -r '.providers | length')"
if ! printf '%s' "$final_outpost_json" | jq -e --arg traefik "$traefik_provider_id" --arg longhorn "$longhorn_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($traefik) != null and index($longhorn) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain both provider IDs"
fi

if ! printf '%s' "$final_outpost_json" | jq -e --arg hubble "$hubble_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($hubble) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain the Hubble provider ID"
fi

if ! printf '%s' "$final_outpost_json" | jq -e --arg proxmox "$proxmox_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($proxmox) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain the Proxmox provider ID"
fi

if ! printf '%s' "$final_outpost_json" | jq -e --arg twinboxwizard "$twinboxwizard_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($twinboxwizard) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain the Twinbox Wizard provider ID"
fi

if ! printf '%s' "$final_outpost_json" | jq -e --arg seaweedfs "$seaweedfs_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($seaweedfs) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain the SeaweedFS provider ID"
fi

if ! printf '%s' "$final_outpost_json" | jq -e --arg seaweedfs_admin "$seaweedfs_admin_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($seaweedfs_admin) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain the SeaweedFS admin provider ID"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Embedded Authentik outpost now has ${final_provider_count} proxy provider(s)"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg traefik_route "traefik-dashboard" \
    --arg longhorn_route "longhorn" \
    --arg hubble_route "hubble" \
    --arg proxmox_route "proxmox" \
    --arg twinboxwizard_route "twinboxwizard" \
    --arg seaweedfs_route "seaweedfs" \
    --arg seaweedfs_admin_route "seaweedfs-admin" \
    '{
      traefik_route: $traefik_route,
      longhorn_route: $longhorn_route,
      hubble_route: $hubble_route,
      proxmox_route: $proxmox_route,
      twinboxwizard_route: $twinboxwizard_route,
      seaweedfs_route: $seaweedfs_route,
      seaweedfs_admin_route: $seaweedfs_admin_route
    }' >"$STEP_RESULT_FILE"
fi
