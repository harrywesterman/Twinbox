#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id // empty')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id // empty')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"
[[ -f "$KUBECONFIG_FILE" ]] || fail "KUBECONFIG_FILE does not exist"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

headwind_db_username="hmdm"
headwind_db_password="$(openssl rand -hex 24)"
headwind_admin_password="$(openssl rand -hex 32)"
headwind_device_admin_password="$(openssl rand -hex 16)"
headwind_shared_secret="$(openssl rand -hex 32)"
headwind_secret_file="$(mktemp "${TMPDIR:-/tmp}/headwind-mdm-bootstrap-XXXXXX")"
trap 'rm -f "$headwind_secret_file"' EXIT

existing_headwind_secret_json=""
if command -v openbao_read_global_secret_json >/dev/null 2>&1; then
  existing_headwind_secret_json="$(openbao_read_global_secret_json headwind-mdm 2>/dev/null || true)"
fi

if [[ -n "$existing_headwind_secret_json" ]]; then
  existing_db_username="$(jq -r '.HEADWIND_POSTGRESQL__USERNAME // empty' <<<"$existing_headwind_secret_json")"
  existing_db_password="$(jq -r '.HEADWIND_POSTGRESQL__PASSWORD // empty' <<<"$existing_headwind_secret_json")"
  existing_admin_password="$(jq -r '.HEADWIND_ADMIN_PASSWORD // empty' <<<"$existing_headwind_secret_json")"
  existing_device_admin_password="$(jq -r '.HEADWIND_DEVICE_ADMIN_PASSWORD // empty' <<<"$existing_headwind_secret_json")"
  existing_shared_secret="$(jq -r '.HEADWIND_SHARED_SECRET // empty' <<<"$existing_headwind_secret_json")"
  [[ -n "$existing_db_username" ]] && headwind_db_username="$existing_db_username"
  [[ -n "$existing_db_password" ]] && headwind_db_password="$existing_db_password"
  [[ -n "$existing_admin_password" ]] && headwind_admin_password="$existing_admin_password"
  [[ -n "$existing_device_admin_password" ]] && headwind_device_admin_password="$existing_device_admin_password"
  [[ -n "$existing_shared_secret" ]] && headwind_shared_secret="$existing_shared_secret"
fi

log "Writing Headwind MDM runtime credentials to OpenBao"
jq -n \
  --arg HEADWIND_POSTGRESQL__USERNAME "$headwind_db_username" \
  --arg HEADWIND_POSTGRESQL__PASSWORD "$headwind_db_password" \
  --arg HEADWIND_ADMIN_PASSWORD "$headwind_admin_password" \
  --arg HEADWIND_DEVICE_ADMIN_PASSWORD "$headwind_device_admin_password" \
  --arg HEADWIND_SHARED_SECRET "$headwind_shared_secret" \
  '{
    HEADWIND_POSTGRESQL__USERNAME: $HEADWIND_POSTGRESQL__USERNAME,
    HEADWIND_POSTGRESQL__PASSWORD: $HEADWIND_POSTGRESQL__PASSWORD,
    HEADWIND_ADMIN_PASSWORD: $HEADWIND_ADMIN_PASSWORD,
    HEADWIND_DEVICE_ADMIN_PASSWORD: $HEADWIND_DEVICE_ADMIN_PASSWORD,
    HEADWIND_SHARED_SECRET: $HEADWIND_SHARED_SECRET
  }' >"$headwind_secret_file"
bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "headwind-mdm" \
  --json-file "$headwind_secret_file" \
  --required-keys "HEADWIND_POSTGRESQL__USERNAME,HEADWIND_POSTGRESQL__PASSWORD,HEADWIND_ADMIN_PASSWORD,HEADWIND_DEVICE_ADMIN_PASSWORD,HEADWIND_SHARED_SECRET"

log "Applying Headwind MDM Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/optional-apps/headwind-mdm.yaml" \
  --application "headwind-mdm" \
  --destination-namespace "headwind-mdm"

log "Registering the private Headwind MDM console with NetBird"
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "headwind-mdm" \
  --service-domain "mdm-admin.${public_zone_name}" \
  --service-path /

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg application "headwind-mdm" \
    --arg enrollment_url "https://mdm.${public_zone_name}" \
    --arg management_url "https://mdm-admin.${public_zone_name}" \
    '{
      application: $application,
      enrollment_url: $enrollment_url,
      management_url: $management_url,
      netbird_confirmation_required: true
    }' >"$STEP_RESULT_FILE"
fi
