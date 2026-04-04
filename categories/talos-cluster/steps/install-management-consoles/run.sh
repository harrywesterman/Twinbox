#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"

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

authentik_secret_json="$(openbao_read_global_secret_json authentik)"
authentik_host="$(jq -r '.AUTHENTIK_HOST // empty' <<<"$authentik_secret_json")"
authentik_token="$(jq -r '.AUTHENTIK_BOOTSTRAP_TOKEN // empty' <<<"$authentik_secret_json")"

if [[ -z "$authentik_host" ]]; then
  authentik_host="https://authentik.${public_zone_name}"
fi

[[ -n "$authentik_token" ]] || fail "Could not read AUTHENTIK_BOOTSTRAP_TOKEN from OpenBao"

for attempt in $(seq 1 120); do
  if kubectl -n traefik get ingressroute/traefik-dashboard >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/longhorn >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/proxmox >/dev/null 2>&1 && \
     kubectl -n longhorn-system get ingressroute/twinboxwizard >/dev/null 2>&1; then
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
authentik_url = "${authentik_host}"
traefik_dashboard_external_host = "https://traefik.${public_zone_name}"
longhorn_external_host = "https://longhorn.${public_zone_name}"
proxmox_external_host = "https://proxmox.${public_zone_name}"
twinboxwizard_external_host = "https://twinboxwizard.${public_zone_name}"
EOF

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Provisioning Authentik proxy applications for Traefik, Longhorn, Proxmox, and Twinbox Wizard"
cd "$tf_workdir"
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu init -no-color -input=false
TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu apply -no-color -auto-approve -input=false

provider_ids_json="$(TF_IN_AUTOMATION=1 AUTHENTIK_TOKEN="$authentik_token" tofu output -no-color -json provider_ids)"
traefik_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.traefik_dashboard')"
longhorn_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.longhorn')"
proxmox_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.proxmox')"
twinboxwizard_provider_id="$(printf '%s' "$provider_ids_json" | jq -r '.twinboxwizard')"
[[ "$traefik_provider_id" != "null" && -n "$traefik_provider_id" ]] || fail "Could not read Traefik provider ID from tofu output"
[[ "$longhorn_provider_id" != "null" && -n "$longhorn_provider_id" ]] || fail "Could not read Longhorn provider ID from tofu output"
[[ "$proxmox_provider_id" != "null" && -n "$proxmox_provider_id" ]] || fail "Could not read Proxmox provider ID from tofu output"
[[ "$twinboxwizard_provider_id" != "null" && -n "$twinboxwizard_provider_id" ]] || fail "Could not read Twinbox Wizard provider ID from tofu output"

AUTHENTIK_LOCAL_FORWARD_PORT="${AUTHENTIK_LOCAL_FORWARD_PORT:-18299}"
AUTHENTIK_API_BASE="http://127.0.0.1:${AUTHENTIK_LOCAL_FORWARD_PORT}/api/v3"

authentik_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response_file
  local status

  response_file="$(mktemp)"

  if [[ -n "$data" ]]; then
    status="$(
      curl -sS \
        -X "$method" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${authentik_token}" \
        -H "Content-Type: application/json" \
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
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${authentik_token}" \
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

authentik_wait_for_local_forward() {
  local forward_port="$1"
  local forward_pid="$2"
  local forward_log="$3"
  local attempt=1
  local attempts=60

  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsS "http://127.0.0.1:${forward_port}/-/health/live/" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$forward_pid" >/dev/null 2>&1; then
      if [[ -s "$forward_log" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Authentik port-forward exited early; last log lines:" >&2
        tail -n 20 "$forward_log" >&2
      fi
      fail "Authentik port-forward on 127.0.0.1:${forward_port} exited before it became ready"
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  if [[ -s "$forward_log" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Authentik port-forward log:" >&2
    tail -n 20 "$forward_log" >&2
  fi

  fail "Authentik port-forward on 127.0.0.1:${forward_port} did not become ready"
}

forward_log="$(mktemp "${TMPDIR:-/tmp}/authentik-port-forward.XXXXXX.log")"
kubectl -n authentik port-forward svc/authentik-server "${AUTHENTIK_LOCAL_FORWARD_PORT}:80" >"$forward_log" 2>&1 &
port_forward_pid="$!"
trap 'kill "$port_forward_pid" >/dev/null 2>&1 || true; rm -f "$forward_log"' EXIT
authentik_wait_for_local_forward "$AUTHENTIK_LOCAL_FORWARD_PORT" "$port_forward_pid" "$forward_log"

outpost_json="$(authentik_request GET "/outposts/instances/?page_size=100")"
outpost_id="$(printf '%s' "$outpost_json" | jq -r '.results[] | select(.name == "authentik Embedded Outpost") | .pk' | head -n1)"
[[ -n "$outpost_id" && "$outpost_id" != "null" ]] || fail "Could not find the embedded Authentik outpost"

current_providers="$(printf '%s' "$outpost_json" | jq -c '.results[] | select(.pk == "'"$outpost_id"'") | .providers // []')"
updated_providers="$(
  printf '%s\n' "$current_providers" \
    | jq --arg traefik "$traefik_provider_id" --arg longhorn "$longhorn_provider_id" --arg proxmox "$proxmox_provider_id" --arg twinboxwizard "$twinboxwizard_provider_id" '
        . + [$traefik, $longhorn, $proxmox, $twinboxwizard]
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
