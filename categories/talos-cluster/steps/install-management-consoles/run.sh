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

tf_workdir="$MANAGER_DATA_DIR/opentofu/authentik-management-consoles-${cluster_id}"
mkdir -p "$tf_workdir"
cp -r "$WORKSPACE_ROOT/infra/opentofu/authentik-management-consoles/"* "$tf_workdir/"

cat >"$tf_workdir/terraform.tfvars" <<EOF
authentik_url = "${AUTHENTIK_HOST}"
traefik_dashboard_external_host = "https://traefik.${public_zone_name}"
longhorn_external_host = "https://longhorn.${public_zone_name}"
proxmox_external_host = "https://proxmox.${public_zone_name}"
twinboxwizard_external_host = "https://twinboxwizard.${public_zone_name}"
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik proxy applications for Traefik, Longhorn, Proxmox, and Twinbox Wizard"
cd "$tf_workdir"
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu init -no-color -input=false
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu apply -no-color -auto-approve -input=false

provider_ids_json="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" tofu output -no-color -json provider_ids)"
traefik_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.traefik_dashboard')"
longhorn_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.longhorn')"
proxmox_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.proxmox')"
  twinboxwizard_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.twinboxwizard')"
  seaweedfs_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.seaweedfs')"
  seaweedfs_admin_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.seaweedfs_admin')"
  [[ "$traefik_provider_id" != "null" && -n "$traefik_provider_id" ]] || fail "Could not read Traefik provider ID from tofu output"
  [[ "$longhorn_provider_id" != "null" && -n "$longhorn_provider_id" ]] || fail "Could not read Longhorn provider ID from tofu output"
  [[ "$proxmox_provider_id" != "null" && -n "$proxmox_provider_id" ]] || fail "Could not read Proxmox provider ID from tofu output"
  [[ "$twinboxwizard_provider_id" != "null" && -n "$twinboxwizard_provider_id" ]] || fail "Could not read Twinbox Wizard provider ID from tofu output"
  [[ "$seaweedfs_provider_id" != "null" && -n "$seaweedfs_provider_id" ]] || fail "Could not read SeaweedFS provider ID from tofu output"
  [[ "$seaweedfs_admin_provider_id" != "null" && -n "$seaweedfs_admin_provider_id" ]] || fail "Could not read SeaweedFS admin provider ID from tofu output"

AUTHENTIK_LOCAL_FORWARD_PORT="${AUTHENTIK_LOCAL_FORWARD_PORT:-18299}"

authentik_setup_forward

authentik_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response_file
  local status

  response_file="$(mktemp)"

  local auth_headers=(-H "Accept: application/json")
  if [[ "${AUTHENTIK_USE_COOKIE:-false}" == "true" ]]; then
    auth_headers+=(-H "Cookie: ${AUTHENTIK_TOKEN}")
  else
    auth_headers+=(-H "Authorization: Bearer ${AUTHENTIK_TOKEN}")
  fi

  if [[ -n "$data" ]]; then
    auth_headers+=(-H "Content-Type: application/json")
    status="$(
      curl -sS \
        -X "$method" \
        "${auth_headers[@]}" \
        --data-binary "$data" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${AUTHENTIK_API_BASE}${path}"
    )" || {
      rm -f "$response_file"
      fail "Authentik API request failed: ${method} ${path}"
    }
  else
    status="$(
      curl -sS \
        -X "$method" \
        "${auth_headers[@]}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "${AUTHENTIK_API_BASE}${path}"
    )" || {
      rm -f "$response_file"
      fail "Authentik API request failed: ${method} ${path}"
    }
  fi

  local body
  body="$(cat "$response_file")"
  rm -f "$response_file"

  if [[ ! "$status" =~ ^2 ]]; then
    if [[ -n "$body" ]]; then
      fail "Authentik API ${method} ${path} failed with HTTP ${status}: ${body}"
    fi
    fail "Authentik API ${method} ${path} failed with HTTP ${status}"
  fi

  printf '%s' "$body"
}

outpost_json="$(authentik_request GET "/outposts/instances/?page_size=100")"
outpost_id="$(printf '%s' "$outpost_json" | jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' | head -n1)"
[[ -n "$outpost_id" && "$outpost_id" != "null" ]] || fail "Could not find the embedded Authentik outpost"

current_providers="$(printf '%s' "$outpost_json" | jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []')"
updated_providers="$(
  printf '%s\n' "$current_providers" \
    | jq --arg traefik "$traefik_provider_id" --arg longhorn "$longhorn_provider_id" --arg proxmox "$proxmox_provider_id" --arg twinboxwizard "$twinboxwizard_provider_id" --arg seaweedfs "$seaweedfs_provider_id" --arg seaweedfs_admin "$seaweedfs_admin_provider_id" '
        . + [$traefik, $longhorn, $proxmox, $twinboxwizard]
        + [$seaweedfs, $seaweedfs_admin]
        | map(tostring)
        | unique
      '
)"

if [[ "$current_providers" != "$updated_providers" ]]; then
  authentik_request PATCH "/outposts/instances/${outpost_id}/" \
    "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
fi

final_outpost_json="$(authentik_request GET "/outposts/instances/${outpost_id}/")"
final_provider_count="$(printf '%s' "$final_outpost_json" | jq -r '.providers | length')"
if ! printf '%s' "$final_outpost_json" | jq -e --arg traefik "$traefik_provider_id" --arg longhorn "$longhorn_provider_id" '
      (.providers // [])
      | map(tostring)
      | index($traefik) != null and index($longhorn) != null
    ' >/dev/null; then
  fail "Embedded Authentik outpost did not retain both provider IDs"
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
    --arg proxmox_route "proxmox" \
    --arg twinboxwizard_route "twinboxwizard" \
    '{
      traefik_route: $traefik_route,
      longhorn_route: $longhorn_route,
      proxmox_route: $proxmox_route,
      twinboxwizard_route: $twinboxwizard_route
    }' >"$STEP_RESULT_FILE"
fi
