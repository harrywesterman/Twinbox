#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

resolve_kubeconfig_file() {
  if [[ -z "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE is required"
  fi

  if [[ ! -f "${KUBECONFIG_FILE:-}" ]]; then
    fail "KUBECONFIG_FILE does not exist at ${KUBECONFIG_FILE:-}"
  fi

  printf '%s\n' "$KUBECONFIG_FILE"
}

wait_for_resource_ready() {
  local namespace="$1"
  local resource="$2"
  local condition="$3"
  local label="$4"
  local attempts=120
  local attempt=1
  local status_json=""
  local message=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get "$resource" -o json 2>/dev/null)"; then
      if kubectl -n "$namespace" wait --for="condition=${condition}" "$resource" --timeout=5s >/dev/null 2>&1; then
        log "${label} is ready"
        return 0
      fi

      message="$(
        jq -r '
          [
            .status.conditions[]?
            | select((.type // "") == $condition)
            | (.reason // empty), (.message // empty)
          ] | map(select(. != "")) | join(": ")
        ' --arg condition "$condition" <<<"$status_json"
      )"
      log "Waiting for ${label} (${attempt}/${attempts})${message:+: ${message}}"
    else
      log "Waiting for ${label} to appear (${attempt}/${attempts})"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become ready after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_pvc_bound() {
  local namespace="$1"
  local pvc="$2"
  local label="$3"
  local attempts=120
  local attempt=1
  local phase=""

  while true; do
    phase="$(kubectl -n "$namespace" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Bound" ]]; then
      log "${label} is bound"
      return 0
    fi

    log "Waiting for ${label} (${attempt}/${attempts}): phase=${phase:-Missing}"
    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become Bound after ${attempts} attempts"
    fi

    sleep 5
    attempt=$((attempt + 1))
  done
}

wait_for_deployment_rollout() {
  local namespace="$1"
  local deployment="$2"
  local label="${3:-$deployment}"
  local attempts=120
  local attempt=1
  local status_json=""
  local desired_replicas=""
  local updated_replicas=""
  local ready_replicas=""
  local available_replicas=""
  local message=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"
      message="$(jq -r '.status.conditions[]? | select(.type == "Progressing" or .type == "Available") | .message // empty' <<<"$status_json" | awk 'NF { if (out) out = out " | "; out = out $0 } END { print out }')"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}${message:+, message=${message}}"
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

find_proxy_provider_pk_by_name() {
  local provider_name="$1"
  local response

  response="$(authentik_api_get "/providers/proxy/?name=$(printf '%s' "$provider_name" | jq -sRr @uri)&page_size=100")"
  jq -r \
    --arg provider_name "$provider_name" \
    '.results[]?
      | select((.name // "") == $provider_name)
      | .pk // .id // empty' <<<"$response" | head -n1
}

find_application_json_by_slug() {
  local application_slug="$1"
  local response

  response="$(authentik_api_get "/core/applications/?slug=$(printf '%s' "$application_slug" | jq -sRr @uri)")"
  jq -c \
    --arg application_slug "$application_slug" \
    '.results[]?
      | select((.slug // "") == $application_slug)' <<<"$response" | head -n1
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
  local existing_json existing_pk

  existing_json="$(find_application_json_by_slug "$application_slug" || true)"
  existing_pk="$(jq -r '.pk // .id // empty' <<<"$existing_json")"
  if [[ -n "$existing_pk" ]]; then
    authentik_api_write PATCH "/core/applications/${application_slug}/" "$application_payload" >/dev/null
    printf '%s\n' "$existing_pk"
    return 0
  fi

  authentik_api_write POST "/core/applications/" "$application_payload" | jq -r '.pk // .id // empty'
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

ensure_provider_on_embedded_outpost() {
  local provider_pk="$1"
  local outpost_response outpost_id current_providers updated_providers

  outpost_response="$(authentik_api_get "/outposts/instances/?page_size=100")"
  outpost_id="$(
    jq -r '.results[]? | select((.name // "") == "authentik Embedded Outpost") | .pk // .id // empty' \
      <<<"$outpost_response" | head -n1
  )"
  [[ -n "$outpost_id" ]] || fail "Could not find the embedded Authentik outpost"

  current_providers="$(
    jq -c --arg outpost_id "$outpost_id" \
      '.results[]? | select(((.pk // .id // "") | tostring) == $outpost_id) | .providers // []' \
      <<<"$outpost_response"
  )"

  if ! jq -e --arg provider_pk "$provider_pk" 'map(tostring) | index($provider_pk) != null' \
    <<<"$current_providers" >/dev/null 2>&1; then
    log "Attaching copyparty proxy provider to the embedded Authentik outpost"
    updated_providers="$(jq -c --argjson provider_pk "$provider_pk" '. + [$provider_pk] | map(tostring) | unique' <<<"$current_providers")"
    authentik_api_write PATCH "/outposts/instances/${outpost_id}/" \
      "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
  fi
}

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

copyparty_admin_username="admin"
copyparty_admin_password="$(openssl rand -base64 36 | tr -d '\n')"
copyparty_fkey_salt="$(openssl rand -hex 32)"
copyparty_dkey_salt="$(openssl rand -hex 32)"
copyparty_host="https://copyparty.${public_zone_name}"

existing_copyparty_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_copyparty_secret_json="$(openbao_read_global_secret_json copyparty 2>/dev/null || true)"
fi

if [[ -n "$existing_copyparty_secret_json" ]]; then
  existing_admin_username="$(jq -r '.COPYPARTY_ADMIN_USERNAME // empty' <<<"$existing_copyparty_secret_json")"
  existing_admin_password="$(jq -r '.COPYPARTY_ADMIN_PASSWORD // empty' <<<"$existing_copyparty_secret_json")"
  existing_fkey_salt="$(jq -r '.COPYPARTY_FKEY_SALT // empty' <<<"$existing_copyparty_secret_json")"
  existing_dkey_salt="$(jq -r '.COPYPARTY_DKEY_SALT // empty' <<<"$existing_copyparty_secret_json")"

  [[ -n "$existing_admin_username" ]] && copyparty_admin_username="$existing_admin_username"
  [[ -n "$existing_admin_password" ]] && copyparty_admin_password="$existing_admin_password"
  [[ -n "$existing_fkey_salt" ]] && copyparty_fkey_salt="$existing_fkey_salt"
  [[ -n "$existing_dkey_salt" ]] && copyparty_dkey_salt="$existing_dkey_salt"
fi

copyparty_secret_file="$(mktemp "${TMPDIR:-/tmp}/copyparty-bootstrap-XXXXXX")"
trap 'authentik_teardown_forward; rm -f "$copyparty_secret_file"' EXIT

jq -n \
  --arg COPYPARTY_ADMIN_USERNAME "$copyparty_admin_username" \
  --arg COPYPARTY_ADMIN_PASSWORD "$copyparty_admin_password" \
  --arg COPYPARTY_FKEY_SALT "$copyparty_fkey_salt" \
  --arg COPYPARTY_DKEY_SALT "$copyparty_dkey_salt" \
  '{
    COPYPARTY_ADMIN_USERNAME: $COPYPARTY_ADMIN_USERNAME,
    COPYPARTY_ADMIN_PASSWORD: $COPYPARTY_ADMIN_PASSWORD,
    COPYPARTY_FKEY_SALT: $COPYPARTY_FKEY_SALT,
    COPYPARTY_DKEY_SALT: $COPYPARTY_DKEY_SALT
  }' >"$copyparty_secret_file"

log "Writing copyparty bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "copyparty" \
  --json-file "$copyparty_secret_file" \
  --required-keys "COPYPARTY_ADMIN_USERNAME,COPYPARTY_ADMIN_PASSWORD,COPYPARTY_FKEY_SALT,COPYPARTY_DKEY_SALT"

log "Configuring Authentik proxy provider for copyparty"
authentik_ensure_token
authentik_setup_forward

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"

provider_payload="$(
  jq -n \
    --arg name "copyparty" \
    --arg external_host "$copyparty_host" \
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

provider_pk="$(create_or_update_proxy_provider "copyparty" "$provider_payload")"
[[ -n "$provider_pk" ]] || fail "Authentik did not return a provider ID for copyparty"

application_payload="$(
  jq -n \
    --arg name "copyparty" \
    --arg slug "copyparty" \
    --arg launch_url "$copyparty_host" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"

application_pk="$(create_or_update_application "copyparty" "$application_payload")"
[[ -n "$application_pk" ]] || fail "Authentik did not return an application ID for copyparty"

if [[ -n "$admins_group_id" ]]; then
  log "Restricting copyparty Authentik application to the admins group"
  ensure_group_binding "$application_pk" "$admins_group_id"
else
  log "Authentik admins group not found; copyparty remains available to authenticated users"
fi
ensure_provider_on_embedded_outpost "$provider_pk"

log "Applying copyparty Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/optional-apps/copyparty.yaml" \
  --application "copyparty" \
  --destination-namespace "copyparty" \
  --no-wait

wait_for_resource_ready "copyparty" "externalsecret/copyparty-config" "Ready" "copyparty ExternalSecret"
wait_for_pvc_bound "copyparty" "copyparty-data" "copyparty data PVC"
wait_for_deployment_rollout "copyparty" "copyparty" "copyparty application"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "copyparty" \
  --service-domain "copyparty.${public_zone_name}" \
  --service-path /
