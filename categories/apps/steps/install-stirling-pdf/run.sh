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
  local progressing_status=""
  local progressing_reason=""
  local available_status=""
  local available_reason=""
  local message=""

  while true; do
    if status_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json 2>/dev/null)"; then
      desired_replicas="$(jq -r '.spec.replicas // 0' <<<"$status_json")"
      updated_replicas="$(jq -r '.status.updatedReplicas // 0' <<<"$status_json")"
      ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$status_json")"
      available_replicas="$(jq -r '.status.availableReplicas // 0' <<<"$status_json")"
      progressing_status="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .status // "Unknown"' <<<"$status_json")"
      progressing_reason="$(jq -r '.status.conditions[]? | select(.type == "Progressing") | .reason // empty' <<<"$status_json")"
      available_status="$(jq -r '.status.conditions[]? | select(.type == "Available") | .status // "Unknown"' <<<"$status_json")"
      available_reason="$(jq -r '.status.conditions[]? | select(.type == "Available") | .reason // empty' <<<"$status_json")"
      message="$(jq -r '.status.conditions[]? | select(.type == "Progressing" or .type == "Available") | .message // empty' <<<"$status_json" | awk 'NF { if (out) out = out " | "; out = out $0 } END { print out }')"

      if [[ "$updated_replicas" == "$desired_replicas" && "$ready_replicas" == "$desired_replicas" && "$available_replicas" == "$desired_replicas" ]]; then
        log "${label} is ready"
        return 0
      fi

      log "Waiting for ${label} (${attempt}/${attempts}): desired=${desired_replicas}, updated=${updated_replicas}, ready=${ready_replicas}, available=${available_replicas}, progressing=${progressing_status}${progressing_reason:+/${progressing_reason}}, available=${available_status}${available_reason:+/${available_reason}}${message:+, message=${message}}"
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

KUBECONFIG_FILE="$(resolve_kubeconfig_file)"
export KUBECONFIG_FILE
export KUBECONFIG="$KUBECONFIG_FILE"

command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

stirling_api_key="$(openssl rand -hex 32)"
existing_stirling_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_stirling_secret_json="$(openbao_read_global_secret_json stirling-pdf 2>/dev/null || true)"
fi

if [[ -n "$existing_stirling_secret_json" ]]; then
  existing_api_key="$(jq -r '.STIRLING_PDF_API_KEY // empty' <<<"$existing_stirling_secret_json" || true)"
  [[ -n "$existing_api_key" ]] && stirling_api_key="$existing_api_key"
fi

stirling_secret_file="$(mktemp "${TMPDIR:-/tmp}/stirling-pdf-bootstrap-XXXXXX")"
stirling_rendered_manifest="$(mktemp "${TMPDIR:-/tmp}/stirling-pdf-application-XXXXXX")"
trap 'rm -f "$stirling_secret_file" "$stirling_rendered_manifest"' EXIT

jq -n \
  --arg STIRLING_PDF_API_KEY "$stirling_api_key" \
  '{
    STIRLING_PDF_API_KEY: $STIRLING_PDF_API_KEY
  }' >"$stirling_secret_file"

log "Writing Stirling PDF bootstrap secret to OpenBao"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "stirling-pdf" \
  --json-file "$stirling_secret_file" \
  --required-keys "STIRLING_PDF_API_KEY"

manifest_path="$WORKSPACE_ROOT/gitops/apps/stirling-pdf.yaml"
log "Applying Stirling PDF Argo CD application"
sed "s/__ZONE_NAME__/${public_zone_name}/g" "$manifest_path" >"$stirling_rendered_manifest"

bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$stirling_rendered_manifest" \
  --application "stirling-pdf" \
  --no-wait

wait_for_resource_ready "stirling-pdf" "externalsecret/stirling-pdf-config" "Ready" "Stirling PDF ExternalSecret"
wait_for_pvc_bound "stirling-pdf" "stirling-pdf-data" "Stirling PDF data PVC"
wait_for_deployment_rollout "stirling-pdf" "stirling-pdf" "Stirling PDF application"

log "Configuring Authentik proxy provider for Stirling PDF"

authentik_ensure_token
authentik_setup_forward

authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"
admins_group_id="$(authentik_find_group_id "admins")"

provider_payload="$(
  jq -n \
    --arg name "Stirling PDF" \
    --arg external_host "https://stirling-pdf.${public_zone_name}" \
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

provider_response="$(authentik_api_request POST "/providers/proxy/" "$provider_payload")"
provider_pk="$(jq -r '.pk // .id // .uuid // empty' <<<"$provider_response")"

if [[ -z "$provider_pk" || "$provider_pk" == "null" ]]; then
  lookup_response="$(authentik_api_request GET "/providers/proxy/?page_size=100")"
  provider_pk="$(jq -r '.results[]? | select(.name == "Stirling PDF") | .pk // .id // .uuid // empty' <<<"$lookup_response")"
fi

[[ -n "$provider_pk" && "$provider_pk" != "null" ]] || fail "Could not determine Authentik proxy provider PK"

application_payload="$(
  jq -n \
    --arg name "Stirling PDF" \
    --arg slug "stirling-pdf" \
    --arg launch_url "https://stirling-pdf.${public_zone_name}" \
    --arg provider_pk "$provider_pk" \
    '{
      name: $name,
      slug: $slug,
      meta_launch_url: $launch_url,
      provider: ($provider_pk | tonumber)
    }'
)"

app_response="$(authentik_api_request POST "/core/applications/" "$application_payload")"
app_pk="$(jq -r '.pk // .id // .uuid // empty' <<<"$app_response")"

if [[ -z "$app_pk" || "$app_pk" == "null" ]]; then
  app_response="$(authentik_api_request GET "/core/applications/stirling-pdf/")"
  app_pk="$(jq -r '.pk // .id // .uuid // empty' <<<"$app_response")"
fi

[[ -n "$app_pk" && "$app_pk" != "null" ]] || fail "Could not determine Authentik application PK"

binding_payload="$(
  jq -n \
    --arg target_uuid "$app_pk" \
    --arg group_id "$admins_group_id" \
    '{target: $target_uuid, group: $group_id, order: 1, enabled: true}'
)"
authentik_api_request POST "/policies/bindings/" "$binding_payload" >/dev/null

outpost_response="$(authentik_api_request GET "/outposts/instances/?page_size=100")"
outpost_id="$(jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' <<<"$outpost_response")"
current_providers="$(jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []' <<<"$outpost_response")"

if ! jq -e --arg pk "$provider_pk" 'map(tostring) | index($pk) != null' <<<"$current_providers" >/dev/null 2>&1; then
  updated_providers="$(jq -c --argjson pk "$provider_pk" '. + [$pk] | map(tostring) | unique' <<<"$current_providers")"
  authentik_api_request PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
fi

authentik_teardown_forward

log "Stirling PDF proxy provider configured in Authentik"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "stirling-pdf" \
    --arg manifest_path "$manifest_path" \
    '{
      application: $application,
      manifest_path: $manifest_path
    }' >"$STEP_RESULT_FILE"
fi

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "stirling-pdf" \
  --service-domain "stirling-pdf.${public_zone_name}" \
  --service-path /
