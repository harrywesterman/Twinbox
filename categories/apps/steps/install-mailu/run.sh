#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
MANAGER_DATA_DIR="${MANAGER_DATA_DIR:-/data}"
STEP_INPUTS_JSON="${STEP_INPUTS_JSON:-{}}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

require_json() {
  local var_name="$1"
  local json="$2"
  if printf '%s' "$json" | jq -e '.' >/dev/null 2>&1; then
    return 0
  fi
  local len="${#json}"
  local snippet="${json:0:120}"
  local last20="${json: -20}"
  local hexdump
  hexdump="$(printf '%s' "$json" | xxd 2>/dev/null || printf '%s' "$json" | od -c)"
  hexdump="$(printf '%s' "$hexdump" | tail -5)"
  log "WARN: ${var_name} initial parse failed (length=${len}) — attempting recovery"
  log "WARN: last20=[${last20}], hex_end=[${hexdump}]"
  local stripped="${json%%\}*}"
  stripped="${stripped}}"
  if printf '%s' "$stripped" | jq -e '.' >/dev/null 2>&1; then
    log "WARN: recovered by stripping trailing braces — proceeding"
    printf -v "${var_name}" '%s' "$stripped"
    return 0
  fi
  fail "${var_name} is not valid JSON (length=${len}, hex_end=[${hexdump}], starts: ${snippet})"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

wait_for_resource() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local condition="$4"
  local label="$5"

  log "Waiting for ${label}"
  kubectl -n "$namespace" wait --for="condition=${condition}" "${kind}/${name}" --timeout=10m
}

wait_for_selector() {
  local namespace="$1"
  local kind="$2"
  local selector="$3"
  local condition="$4"
  local label="$5"

  log "Waiting for ${label}"
  if ! kubectl -n "$namespace" wait --for="condition=${condition}" "$kind" -l "$selector" --timeout=10m; then
    log "Timed out waiting for ${label}; collecting diagnostics"
    kubectl -n "$namespace" get pods -o wide || true
    kubectl -n "$namespace" get pvc || true
    kubectl -n "$namespace" get events --sort-by=.lastTimestamp | tail -80 || true
    kubectl -n "$namespace" describe pods -l "$selector" || true
    return 1
  fi
}

wait_for_statefulsets_ready() {
  local namespace="$1"
  local selector="$2"
  local label="$3"
  local attempts=120
  local attempt=1

  while true; do
    local status_json not_ready
    status_json="$(kubectl -n "$namespace" get statefulset -l "$selector" -o json 2>/dev/null || true)"
    if jq -e '.items | length > 0' >/dev/null 2>&1 <<<"$status_json"; then
      not_ready="$(
        jq -r '
          [
            .items[]
            | select((.spec.replicas // 0) != (.status.readyReplicas // 0))
            | .metadata.name
          ]
          | join(",")
        ' <<<"$status_json"
      )"
      if [[ -z "$not_ready" ]]; then
        log "${label} are ready"
        return 0
      fi
      log "Waiting for ${label}: ${not_ready}"
    else
      log "Waiting for ${label} to appear"
    fi

    if [[ "$attempt" -ge "$attempts" ]]; then
      fail "${label} did not become ready"
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
}

find_netbird_bastion_secret() {
  local cluster_id="$1"
  local candidate

  for candidate in \
    "/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json" \
    "${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global/netbird-bastion-${cluster_id}.json"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  ls -t "${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"/secrets/global/netbird-bastion-*.json 2>/dev/null | head -n1
}

write_bastion_ssh_key() {
  local secret_file="$1"
  local cluster_id="$2"
  local key_content
  local key_file

  key_content="$(jq -r '.SSH_PRIVATE_KEY // empty' "$secret_file")"
  if [[ -n "$key_content" ]]; then
    key_file="$(mktemp "${TMPDIR:-/tmp}/mailu-bastion-key-XXXXXX")"
    printf '%s\n' "$key_content" >"$key_file"
    chmod 600 "$key_file"
    printf '%s\n' "$key_file"
    return 0
  fi

  key_file="$MANAGER_DATA_DIR/ssh/netbird-${cluster_id}/id_ed25519"
  [[ -f "$key_file" ]] || fail "NetBird bastion SSH key not found; provision NetBird bastion with a generated key"
  printf '%s\n' "$key_file"
}

openbao_existing_value() {
  local secret_name="$1"
  local property="$2"
  local json

  json="$(openbao_read_global_secret_json "$secret_name" 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    jq -r --arg property "$property" '.[$property] // empty' <<<"$json"
  fi
}

random_hex() {
  openssl rand -hex "$1"
}

sanitize_label_value() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^[^a-z0-9]+//; s/[^a-z0-9]+$//')"
  value="${value:0:63}"
  [[ -n "$value" ]] || value="mailu"
  printf '%s\n' "$value"
}

# Parse a k8s CPU quantity to milli-cores ("750m" -> 750, "2" -> 2000, "0.5" -> 500).
cpu_to_millicores() {
  local value="$1"
  python3 -c 'import re,sys; v=sys.argv[1]; m=re.match(r"^(\d+(?:\.\d+)?)m?$", v)
if not m: sys.exit(f"unparseable cpu: {v}")
n=float(m.group(1)); print(int(n) if v.endswith("m") else int(n*1000))' "$value"
}

# Parse a k8s memory quantity to Mi ("128Mi" -> 128, "1Gi" -> 1024, "22025760Ki" -> 21509).
mem_to_mib() {
  local value="$1"
  python3 -c 'import re,sys; v=sys.argv[1]; m=re.match(r"^(\d+(?:\.\d+)?)([KMG]i?|)$", v)
if not m: sys.exit(f"unparseable memory: {v}")
n=float(m.group(1)); unit=m.group(2)
mul={"":1,"K":10**3,"Ki":2**10,"M":10**6,"Mi":2**20,"G":10**9,"Gi":2**30}.get(unit,1)
print(int(n*mul//(2**20)))' "$value"
}

choose_mailu_storage_node() {
  local label_value="$1"
  local existing_node candidates_json pods_json alloc_json
  local node used_cpu used_mem used_pods alloc_cpu alloc_mem alloc_pods
  local free_cpu free_mem free_pods free_disk best_node best_disk reason
  local required_pod_slots required_cpu_milli required_mem_mi

  # Idempotent: reuse an existing Ready storage node for this cluster.
  existing_node="$(
    kubectl get nodes -l "twinbox.io/mailu-storage-node=${label_value}" -o json |
      jq -r '
        .items[]
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name
      ' |
      head -n1
  )"
  if [[ -n "$existing_node" ]]; then
    printf '%s\n' "$existing_node"
    return 0
  fi

  # Must-fit budget for the pinned Mailu workloads (front/admin/postfix/dovecot/rspamd/webmail).
  required_pod_slots="${MAILU_PINNED_POD_SLOTS:-8}"
  required_cpu_milli="${MAILU_PINNED_CPU_MILLI:-1000}"
  required_mem_mi="${MAILU_PINNED_MEM_MIB:-2048}"

  candidates_json="$(kubectl get nodes -o json)"
  pods_json="$(kubectl get pods -A -o json)"

  best_node=""
  best_disk=-1

  for node in $(
    printf '%s' "$candidates_json" | jq -r '
      .items[]
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | select((.spec.unschedulable // false) == false)
      | select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) == false)
      | .metadata.name
    '
  ); do
    alloc_json="$(printf '%s' "$candidates_json" | jq -c --arg n "$node" '
      .items[] | select(.metadata.name == $n) | .status.allocatable
    ')"

    alloc_cpu="$(printf '%s' "$alloc_json" | jq -r '.cpu // "0"')"
    alloc_mem="$(printf '%s' "$alloc_json" | jq -r '.memory // "0"')"
    alloc_pods="$(printf '%s' "$alloc_json" | jq -r '.pods // "0"')"
    alloc_cpu="$(cpu_to_millicores "$alloc_cpu")"
    alloc_mem="$(mem_to_mib "$alloc_mem")"

    used_json="$(printf '%s' "$pods_json" | jq -c --arg n "$node" '
      [ .items[]
        | select((.spec.nodeName // "") == $n)
        | .spec.containers[]?
        | .resources.requests
      ] as $reqs
      | {
          pods: ([ .items[] | select((.spec.nodeName // "") == $n) ] | length),
          cpu_milli: ( [ $reqs[] | .cpu? // "0"
                         | if endswith("m") then (. | rtrimstr("m") | tonumber)
                           else (tonumber * 1000) end ] | add // 0 ),
          mem_mi: ( [ $reqs[] | .memory? // "0"
                      | if endswith("Ki") then (. | rtrimstr("Ki") | tonumber / 1024 | floor)
                        elif endswith("Mi") then (. | rtrimstr("Mi") | tonumber | floor)
                        elif endswith("Gi") then (. | rtrimstr("Gi") | tonumber * 1024 | floor)
                        elif endswith("Ti") then (. | rtrimstr("Ti") | tonumber * 1024 * 1024 | floor)
                        else (tonumber / 1024 / 1024 | floor) end ] | add // 0 )
        }
    ')"

    used_pods="$(printf '%s' "$used_json" | jq -r '.pods')"
    used_cpu="$(printf '%s' "$used_json" | jq -r '.cpu_milli')"
    used_mem="$(printf '%s' "$used_json" | jq -r '.mem_mi')"

    free_pods=$((alloc_pods - used_pods))
    free_cpu=$((alloc_cpu - used_cpu))
    free_mem=$((alloc_mem - used_mem))

    # Prefer Longhorn's true storage availability; fall back to ephemeral-storage.
    if kubectl -n longhorn-system get "nodes.longhorn.io/$node" >/dev/null 2>&1; then
      free_disk="$(
        kubectl -n longhorn-system get "nodes.longhorn.io/$node" -o json |
          jq '[.status.diskStatus[]?.storageAvailable // 0] | add // 0'
      )"
      free_disk="$(mem_to_mib "$free_disk")"
    else
      free_disk="$(
        kubectl get "nodes/$node" -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null
      )"
      free_disk="${free_disk:-0}"
      free_disk="$(mem_to_mib "$free_disk")"
    fi

    reason=""
    if [[ "$free_pods" -lt "$required_pod_slots" ]]; then
      reason="${reason} pods free=${free_pods}<${required_pod_slots}"
    fi
    if [[ "$free_cpu" -lt "$required_cpu_milli" ]]; then
      reason="${reason} cpu_milli free=${free_cpu}<${required_cpu_milli}"
    fi
    if [[ "$free_mem" -lt "$required_mem_mi" ]]; then
      reason="${reason} mem_mi free=${free_mem}<${required_mem_mi}"
    fi

    if [[ -n "$reason" ]]; then
      log "Mailu storage-node candidate ${node} rejected:${reason} (disk_mi=${free_disk})"
      continue
    fi

    if [[ "$free_disk" -gt "$best_disk" ]]; then
      best_disk="$free_disk"
      best_node="$node"
    fi
    log "Mailu storage-node candidate ${node} fits: disk_mi=${free_disk}, pods_free=${free_pods}, cpu_milli_free=${free_cpu}, mem_mi_free=${free_mem}"
  done

  if [[ -z "$best_node" ]]; then
    fail "No Ready schedulable worker has capacity to host Mailu. Required: pods>=${required_pod_slots}, cpu>=${required_cpu_milli}m, mem>=${required_mem_mi}Mi. See per-candidate log lines above. Free disk space or move workloads off full workers before retrying."
  fi

  log "Choosing ${best_node} as Mailu storage node (free disk ${best_disk} Mi)"
  kubectl label node "$best_node" "twinbox.io/mailu-storage-node=${label_value}" --overwrite >/dev/null
  printf '%s\n' "$best_node"
}

generate_mailu_tls_secret_file() {
  local mail_hostname="$1"
  local output_file="$2"
  local cert_file key_file

  cert_file="$(mktemp "${TMPDIR:-/tmp}/mailu-cert-XXXXXX")"
  key_file="$(mktemp "${TMPDIR:-/tmp}/mailu-key-XXXXXX")"
  openssl req -x509 \
    -newkey rsa:2048 \
    -nodes \
    -sha256 \
    -days 825 \
    -subj "/CN=${mail_hostname}" \
    -addext "subjectAltName=DNS:${mail_hostname}" \
    -keyout "$key_file" \
    -out "$cert_file" >/dev/null 2>&1
  jq -n \
    --arg mail_hostname "$mail_hostname" \
    --rawfile tls_crt "$cert_file" \
    --rawfile tls_key "$key_file" \
    '{
      "mail-hostname": $mail_hostname,
      "tls.crt": $tls_crt,
      "tls.key": $tls_key
    }' >"$output_file"
  chmod 600 "$output_file"
  rm -f "$cert_file" "$key_file"
}

validate_storage_size() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+(Gi|Mi|Ti)$ ]] || fail "storage_size must look like 100Gi, 512Mi, or 1Ti"
}

normalize_localpart() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._%+-]+$ ]] || fail "localpart contains unsupported characters: $value"
  printf '%s\n' "$value"
}

resolve_admin_pod() {
  kubectl -n mailu get pods \
    -l app.kubernetes.io/instance=mailu,app.kubernetes.io/component=admin \
    -o json |
    jq -r '.items[] | select((.status.phase // "") == "Running") | .metadata.name' |
    head -n1
}

register_mailu_authentik_app() {
  local public_zone_name="$1"

  log "Registering Mailu in Authentik (proxy provider)"

  authentik_ensure_token
  authentik_setup_forward

  authorization_flow_id="$(authentik_resolve_flow_id "default-provider-authorization-implicit-consent" "authorization")"
  invalidation_flow_id="$(authentik_resolve_flow_id "default-provider-invalidation-flow" "invalidation")"

  local provider_payload provider_pk app_pk policy_pk

  provider_payload="$(jq -n \
    --arg name "Mailu" \
    --arg external_host "https://mail.${public_zone_name}" \
    --arg authorization_flow "$authorization_flow_id" \
    --arg invalidation_flow "$invalidation_flow_id" \
    '{name: $name, external_host: $external_host, authorization_flow: $authorization_flow, invalidation_flow: $invalidation_flow, mode: "forward_single"}')"
  provider_pk="$(authentik_api_request POST "/providers/proxy/" "$provider_payload" | jq -r ".pk // empty")"
  if [[ -z "$provider_pk" || "$provider_pk" == "null" ]]; then
    provider_pk="$(authentik_api_request GET "/providers/proxy/?name=Mailu" | jq -r ".results[0].pk // empty")"
  fi
  [[ -n "$provider_pk" && "$provider_pk" != "null" ]] || fail "Could not create Mailu Authentik proxy provider"

  app_pk="$(authentik_api_request GET "/core/applications/mailu/" 2>/dev/null | jq -r ".pk // empty")"
  if [[ -z "$app_pk" || "$app_pk" == "null" ]]; then
    local app_payload
    app_payload="$(jq -n \
      --arg name "Mailu" \
      --arg slug "mailu" \
      --arg launch_url "https://mail.${public_zone_name}" \
      --arg provider_pk "$provider_pk" \
      '{name: $name, slug: $slug, meta_launch_url: $launch_url, provider: ($provider_pk | tonumber)}')"
    app_pk="$(authentik_api_request POST "/core/applications/" "$app_payload" | jq -r ".pk // empty")"
  fi
  [[ -n "$app_pk" && "$app_pk" != "null" ]] || fail "Could not create Mailu Authentik application"

  policy_pk="$(authentik_api_request GET "/policies/expression/?name=allow-all-authenticated" | jq -r ".results[0].pk // empty")"
  if [[ -z "$policy_pk" || "$policy_pk" == "null" ]]; then
    policy_pk="$(authentik_api_request POST "/policies/expression/" \
      "{\"name\":\"allow-all-authenticated\",\"execution_logging\":false,\"expression\":\"return True\"}" | jq -r ".pk // empty")"
  fi
  [[ -n "$policy_pk" && "$policy_pk" != "null" ]] || fail "Could not create allow-all expression policy"

  local existing_bindings
  existing_bindings="$(authentik_api_request GET "/policies/bindings/?target=${app_pk}" | jq -r ".results[].pk // empty")"
  while IFS= read -r bind_pk; do
    [[ -n "$bind_pk" ]] && authentik_api_request DELETE "/policies/bindings/${bind_pk}/" >/dev/null 2>&1 || true
  done <<<"$existing_bindings"

  local binding_payload
  binding_payload="$(jq -n --arg target "$app_pk" --arg policy "$policy_pk" '{target: $target, policy: $policy, order: 0, enabled: true}')"
  authentik_api_request POST "/policies/bindings/" "$binding_payload" >/dev/null 2>&1 || fail "Could not create policy binding"

  local outpost_id current_providers updated_providers
  outpost_id="$(authentik_api_request GET "/outposts/instances/?name=authentik Embedded Outpost" | jq -r ".results[0].pk // empty")"
  if [[ -n "$outpost_id" && "$outpost_id" != "null" ]]; then
    current_providers="$(authentik_api_request GET "/outposts/instances/${outpost_id}/" | jq -c "[.providers[]]")"
    if ! jq -e --arg pk "$provider_pk" "map(tostring) | index(\$pk) != null" <<<"$current_providers" >/dev/null 2>&1; then
      updated_providers="$(jq -c --arg pk "$provider_pk" ". + [(\$pk | tonumber)] | unique" <<<"$current_providers")"
      authentik_api_request PATCH "/outposts/instances/${outpost_id}/" "{\"providers\":$updated_providers}" >/dev/null 2>&1 || true
    fi
  fi

  authentik_teardown_forward
  log "Mailu registered in Authentik (webmail accessible to all authenticated users)"
}

sync_mailu_mailboxes() {
  local mail_domain="$1"
  local api_token="$2"

  if [[ -z "$api_token" ]]; then
    log "No Mailu API token available; skipping mailbox sync"
    return 0
  fi

  local api_base="https://mail.${mail_domain}/api/v1"
  local users_json

  log "Syncing Mailu mailboxes for existing Authentik users"

  users_json="$(authentik_api_get "/core/users/" 2>/dev/null | jq '[.results[] | select(.email != null and .email != "") | {email, name, username}]')"
  if [[ -z "$users_json" || "$users_json" == "null" || "$users_json" == "[]" ]]; then
    log "No Authentik users with email addresses found; skipping mailbox sync"
    return 0
  fi

  local total=0 created=0 existed=0 failed=0
  total="$(jq length <<<"$users_json")"
  log "Found ${total} Authentik user(s) with email to sync"

  while IFS= read -r user_entry; do
    local email name displayed
    email="$(jq -r '.email' <<<"$user_entry")"
    name="$(jq -r '.name // .username' <<<"$user_entry")"
    displayed="${name:-$email}"

    local check_status
    check_status="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${api_token}" \
      "${api_base}/user/$(printf '%s' "$email" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')" \
      2>/dev/null || echo "000")"

    if [[ "$check_status" == "200" ]]; then
      existed=$((existed + 1))
      log "  SKIP ${email}: mailbox already exists"
      continue
    fi

    local raw_password
    raw_password="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"

    local create_status
    create_status="$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${api_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg email "$email" --arg pwd "$raw_password" --arg name "$displayed" \
        '{email: $email, raw_password: $pwd, displayed_name: $name, enabled: true, enable_imap: true, enable_pop: false, spam_enabled: true}')" \
      "${api_base}/user" 2>/dev/null || echo "000")"

    if [[ "$create_status" == "200" ]]; then
      created=$((created + 1))
      log "  OK   ${email}: mailbox created"
    else
      failed=$((failed + 1))
      log "  FAIL ${email}: HTTP ${create_status}"
    fi
  done < <(jq -c '.[]' <<<"$users_json")

  log "Mailbox sync complete: ${total} total, ${created} created, ${existed} existed, ${failed} failed"
}

extract_dkim_from_export() {
  jq -c -f "$WORKSPACE_ROOT/scripts/manager/mailu-dns-export-to-dkim.jq"
}

apply_mail_dns_records() {
  local mail_domain="$1"
  local mail_hostname="$2"
  local bastion_ip="$3"
  local dkim_name="$4"
  local dkim_value="$5"
  local dmarc_policy="$6"
  local dmarc_rua_localpart="$7"

  local dmarc_value="v=DMARC1; p=${dmarc_policy}; rua=mailto:${dmarc_rua_localpart}@${mail_domain}; adkim=s; aspf=s"

  jq -n \
    --arg mail_hostname "$mail_hostname" \
    --arg bastion_ip "$bastion_ip" \
    --arg mail_domain "$mail_domain" \
    --arg dmarc_value "$dmarc_value" \
    --arg dkim_name "$dkim_name" \
    --arg dkim_value "$dkim_value" \
    '{
      apiVersion: "externaldns.k8s.io/v1alpha1",
      kind: "DNSEndpoint",
      metadata: {
        name: "mailu-mail-dns",
        namespace: "external-dns"
      },
      spec: {
        endpoints: [
          {
            dnsName: $mail_hostname,
            recordType: "A",
            targets: [$bastion_ip],
            recordTTL: 300
          },
          {
            dnsName: $mail_domain,
            recordType: "MX",
            targets: ["10 \($mail_hostname)."],
            recordTTL: 300
          },
          {
            dnsName: $mail_domain,
            recordType: "TXT",
            targets: ["v=spf1 mx -all"],
            recordTTL: 300
          },
          {
            dnsName: "_dmarc.\($mail_domain)",
            recordType: "TXT",
            targets: [$dmarc_value],
            recordTTL: 300
          },
          {
            dnsName: $dkim_name,
            recordType: "TXT",
            targets: [$dkim_value],
            recordTTL: 300
          }
        ]
      }
    }' | kubectl apply -f -
}

ssh_bastion() {
  local bastion_ssh_host="$1"
  local bastion_ssh_port="$2"
  local bastion_ssh_user="$3"
  local ssh_key_file="$4"
  shift 4

  ssh -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -p "$bastion_ssh_port" \
    -i "$ssh_key_file" \
    "${bastion_ssh_user}@${bastion_ssh_host}" \
    "$@"
}

discover_bastion_netbird_ip() {
  local bastion_ssh_host="$1"
  local bastion_ssh_port="$2"
  local bastion_ssh_user="$3"
  local ssh_key_file="$4"

  ssh_bastion "$bastion_ssh_host" "$bastion_ssh_port" "$bastion_ssh_user" "$ssh_key_file" 'bash -s' <<'REMOTE'
set -euo pipefail
docker exec netbird-client netbird status --check ready >/dev/null
netbird_ip="$(docker exec netbird-client netbird status 2>/dev/null | awk '/NetBird IP:/ {gsub(/\/.*/, ""); print $NF; exit}')"
if [[ -z "$netbird_ip" ]]; then
  netbird_ip="$(docker exec netbird-client sh -lc "ip -o -4 addr show | awk '\$2 ~ /^(wt|nb|netbird)/ {split(\$4,a,\"/\"); print a[1]; exit}'" 2>/dev/null || true)"
fi
[[ -n "$netbird_ip" ]] || {
  echo "Could not discover NetBird overlay IP from netbird-client" >&2
  exit 1
}
printf '%s\n' "$netbird_ip"
REMOTE
}

verify_bastion_mailu_path() {
  local bastion_ssh_host="$1"
  local bastion_ssh_port="$2"
  local bastion_ssh_user="$3"
  local ssh_key_file="$4"
  local mailu_front_address="$5"
  local mailu_front_port="$6"
  local relay_host="$7"

  log "Verifying bastion NetBird route to Mailu front"
  ssh_bastion "$bastion_ssh_host" "$bastion_ssh_port" "$bastion_ssh_user" "$ssh_key_file" 'bash -s' <<REMOTE
set -euo pipefail
docker exec netbird-client netbird status --check ready >/dev/null
ip route get ${mailu_front_address} >/dev/null
timeout 5 bash -c '</dev/tcp/${mailu_front_address}/${mailu_front_port}'
if ! ip -o -4 addr show | awk '{print \$4}' | grep -Eq '^${relay_host}/'; then
  echo "Relay host ${relay_host} is not configured on the bastion host" >&2
  exit 1
fi
REMOTE
}

verify_mailu_relay_egress_path() {
  local relay_host="$1"
  local relay_port="$2"
  local egress_pod

  log "Verifying Mailu relay egress path to bastion"
  kubectl -n netbird wait \
    --for=condition=Available \
    deployment/mailu-relay-egress \
    --timeout=10m

  egress_pod="$(
    kubectl -n netbird get pods \
      -l app.kubernetes.io/name=mailu-relay-egress \
      -o jsonpath='{.items[0].metadata.name}'
  )"
  [[ -n "$egress_pod" ]] || fail "Could not find Mailu relay egress pod"

  kubectl -n netbird exec "$egress_pod" -c netbird -- netbird status --check ready >/dev/null
  kubectl -n netbird exec "$egress_pod" -c probe -- nc -z -w 5 "$relay_host" "$relay_port"

  kubectl -n mailu run mailu-relay-egress-check \
    --rm \
    -i \
    --restart=Never \
    --image=busybox:1.36 \
    --command -- nc -z -w 5 mailu-relay-egress.netbird.svc.cluster.local 2525
}

export KUBECONFIG="$KUBECONFIG_FILE"
require_cmd jq
require_cmd kubectl
require_cmd openssl
require_cmd python3
require_cmd ssh

require_json STEP_CONTEXT_JSON "$STEP_CONTEXT_JSON"
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_scope_id="$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // .instance_id // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_scope_id" ]] || fail "Could not determine cluster scope ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain; run choose-ingress-route first"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

require_json STEP_INPUTS_JSON "$STEP_INPUTS_JSON"
admin_localpart="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.admin_localpart // "admin"')"
admin_localpart="$(normalize_localpart "$admin_localpart")"
admin_password_input="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.admin_password // empty')"
storage_size="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.storage_size // "100Gi"')"
dmarc_policy="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dmarc_policy // "quarantine"')"
dmarc_rua_localpart="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dmarc_rua_localpart // "dmarc"')"
confirm_manual_rdns="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.confirm_manual_rdns // .skip_rdns_automation_acknowledged // "false"')"
validate_storage_size "$storage_size"
normalize_localpart "$dmarc_rua_localpart" >/dev/null
case "$dmarc_policy" in
  none|quarantine|reject) ;;
  *) fail "dmarc_policy must be none, quarantine, or reject" ;;
esac

mail_domain="$public_zone_name"
mail_hostname="mail.${public_zone_name}"
admin_url="https://${mail_hostname}/admin"
webmail_url="https://${mail_hostname}/webmail"
mailu_storage_node_label="$(sanitize_label_value "$cluster_slug")"

netbird_bastion_secret="$(find_netbird_bastion_secret "$cluster_id")"
[[ -n "$netbird_bastion_secret" && -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found; provision NetBird bastion first"

bastion_ip="$(jq -r '.BASTION_PUBLIC_IPV4 // .NETBIRD_IP // empty' "$netbird_bastion_secret")"
bastion_ssh_host="$(jq -r '.BASTION_SSH_HOST // .NETBIRD_IP // empty' "$netbird_bastion_secret")"
bastion_ssh_port="$(jq -r '.BASTION_SSH_PORT // "22"' "$netbird_bastion_secret")"
bastion_ssh_user="$(jq -r '.BASTION_SSH_USER // "root"' "$netbird_bastion_secret")"
bastion_provider="$(jq -r 'if .BASTION_PROVIDER then .BASTION_PROVIDER elif .HCLOUD_TOKEN then "hetzner" else "existing-vm" end' "$netbird_bastion_secret")"
hcloud_token="$(jq -r '.HCLOUD_TOKEN // empty' "$netbird_bastion_secret")"
mailu_relay_host="$(jq -r '.NETBIRD_RELAY_HOST // empty' "$netbird_bastion_secret")"
if [[ -z "$mailu_relay_host" ]]; then
  mailu_relay_host="$(jq -r '.NETBIRD_PRIVATE_IP // empty' "$netbird_bastion_secret" | awk 'match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/) {print substr($0, RSTART, RLENGTH); exit}')"
fi
[[ -n "$bastion_ip" ]] || fail "NetBird bastion secret is missing BASTION_PUBLIC_IPV4 or NETBIRD_IP"
[[ -n "$bastion_ssh_host" ]] || fail "NetBird bastion secret is missing BASTION_SSH_HOST or NETBIRD_IP"
[[ "$bastion_ssh_port" =~ ^[0-9]+$ ]] || fail "NetBird bastion secret contains invalid BASTION_SSH_PORT"
[[ -n "$bastion_ssh_user" ]] || fail "NetBird bastion secret contains empty BASTION_SSH_USER"

ptr_required="${bastion_ip} -> ${mail_hostname}"
rdns_status="manual-required"
if [[ "$bastion_provider" != "hetzner" || -z "$hcloud_token" ]]; then
  if [[ "$confirm_manual_rdns" != "true" ]]; then
    fail "Mailu on a non-Hetzner or non-automated bastion requires confirm_manual_rdns=true after you can create/verify PTR ${ptr_required} and confirm TCP 25 is allowed"
  fi
  log "PTR/rDNS automation is not available for bastion provider ${bastion_provider}; create/verify PTR ${ptr_required} manually"
fi

server_name="twinbox-${cluster_id}-netbird"
legacy_server_name="netbird-${cluster_id}"

ssh_key_file="$(write_bastion_ssh_key "$netbird_bastion_secret" "$cluster_id")"
trap '[[ "$ssh_key_file" == /tmp/mailu-bastion-key-* ]] && rm -f "$ssh_key_file" || true' EXIT

if [[ -z "$mailu_relay_host" ]]; then
  log "Discovering bastion NetBird overlay IP for Mailu relay"
  mailu_relay_host="$(discover_bastion_netbird_ip "$bastion_ssh_host" "$bastion_ssh_port" "$bastion_ssh_user" "$ssh_key_file")" || fail "Could not discover existing bastion NetBird peer IP; run/repair configure-netbird-ingress first"
fi
[[ "$mailu_relay_host" != "$bastion_ip" ]] || fail "Refusing to use public bastion IP as Mailu relay host; expected NetBird/private address"
[[ -n "$(openbao_existing_value netbird-mailu-relay-egress NB_SETUP_KEY)" ]] || fail "NetBird Mailu relay egress setup key not found; rerun configure-netbird-ingress before installing Mailu"

secrets_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/global"
mkdir -p "$secrets_dir"
runtime_secret_file="${secrets_dir}/mailu-runtime-${cluster_id}.json"
relay_secret_file="${secrets_dir}/mailu-relay-${cluster_id}.json"
certificates_secret_file="${secrets_dir}/mailu-certificates-${cluster_id}.json"
dns_secret_file="${secrets_dir}/mailu-dns-${cluster_id}.json"
trap 'rm -f "$runtime_secret_file" "$relay_secret_file" "$certificates_secret_file" "$dns_secret_file"; [[ "$ssh_key_file" == /tmp/mailu-bastion-key-* ]] && rm -f "$ssh_key_file" || true' EXIT

secret_key="$(openbao_existing_value mailu-runtime secret-key)"
api_token="$(openbao_existing_value mailu-runtime api-token)"
admin_password="$(openbao_existing_value mailu-runtime initial-admin-password)"
relay_username="$(openbao_existing_value mailu-relay relay-username)"
relay_password="$(openbao_existing_value mailu-relay relay-password)"
tls_crt="$(openbao_existing_value mailu-certificates tls.crt)"
tls_key="$(openbao_existing_value mailu-certificates tls.key)"
tls_cert_hostname="$(openbao_existing_value mailu-certificates mail-hostname)"

[[ -n "$secret_key" ]] || secret_key="$(random_hex 24)"
[[ -n "$api_token" ]] || api_token="$(random_hex 24)"
if [[ -n "$admin_password_input" ]]; then
  admin_password="$admin_password_input"
fi
[[ -n "$admin_password" ]] || admin_password="$(random_hex 18)"
[[ -n "$relay_username" ]] || relay_username="mailu-${cluster_id}"
[[ -n "$relay_password" ]] || relay_password="$(random_hex 24)"

jq -n \
  --arg secret_key "$secret_key" \
  --arg api_token "$api_token" \
  --arg initial_admin_password "$admin_password" \
  --arg mail_api_base_url "https://mail.${mail_domain}/api" \
  '{
    "secret-key": $secret_key,
    "api-token": $api_token,
    "initial-admin-password": $initial_admin_password,
    "MAILU_API_BASE_URL": $mail_api_base_url
  }' >"$runtime_secret_file"
chmod 600 "$runtime_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "mailu-runtime" \
  --json-file "$runtime_secret_file" \
  --required-keys "secret-key,api-token,initial-admin-password,MAILU_API_BASE_URL"

jq -n \
  --arg relay_username "$relay_username" \
  --arg relay_password "$relay_password" \
  '{
    "relay-username": $relay_username,
    "relay-password": $relay_password
  }' >"$relay_secret_file"
chmod 600 "$relay_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "mailu-relay" \
  --json-file "$relay_secret_file" \
  --required-keys "relay-username,relay-password"

if [[ -z "$tls_crt" || -z "$tls_key" || "$tls_cert_hostname" != "$mail_hostname" ]]; then
  log "Generating internal Mailu TLS certificate"
  generate_mailu_tls_secret_file "$mail_hostname" "$certificates_secret_file"
else
  jq -n \
    --arg mail_hostname "$mail_hostname" \
    --arg tls_crt "$tls_crt" \
    --arg tls_key "$tls_key" \
    '{
      "mail-hostname": $mail_hostname,
      "tls.crt": $tls_crt,
      "tls.key": $tls_key
    }' >"$certificates_secret_file"
  chmod 600 "$certificates_secret_file"
fi

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "mailu-certificates" \
  --json-file "$certificates_secret_file" \
  --required-keys "mail-hostname,tls.crt,tls.key"

mailu_storage_node="$(choose_mailu_storage_node "$mailu_storage_node_label")"
log "Using ${mailu_storage_node} as Mailu shared-storage node"

log "Annotating Argo CD cluster secret with Mailu render values"
kubectl -n argocd annotate secret in-cluster-local \
  "twinbox.io/mailu-relay-host=${mailu_relay_host}" \
  "twinbox.io/mailu-admin-localpart=${admin_localpart}" \
  "twinbox.io/mailu-storage-size=${storage_size}" \
  "twinbox.io/mailu-storage-node=${mailu_storage_node_label}" \
  "twinbox.io/mailu-dmarc-rua-localpart=${dmarc_rua_localpart}" \
  --overwrite

log "Applying Mailu Argo CD application"
bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
  --manifest "$WORKSPACE_ROOT/gitops/apps/mailu.yaml" \
  --application "mailu" \
  --destination-namespace "mailu"

wait_for_resource mailu externalsecret mailu-runtime Ready "Mailu runtime ExternalSecret"
wait_for_resource mailu externalsecret mailu-relay Ready "Mailu relay ExternalSecret"
wait_for_resource mailu externalsecret mailu-certificates Ready "Mailu certificates ExternalSecret"
wait_for_resource netbird externalsecret mailu-relay-egress Ready "Mailu relay egress ExternalSecret"
wait_for_selector mailu deployment "app.kubernetes.io/instance=mailu" Available "Mailu deployments"
wait_for_resource netbird deployment mailu-relay-egress Available "Mailu relay egress deployment"
wait_for_statefulsets_ready mailu "app.kubernetes.io/instance=mailu" "Mailu statefulsets"

mailu_front_address="$(kubectl -n mailu get svc mailu-front -o jsonpath='{.spec.clusterIP}')"
[[ -n "$mailu_front_address" && "$mailu_front_address" != "None" ]] || fail "Could not determine mailu-front ClusterIP"

log "Configuring bastion Postfix edge"
bash "$WORKSPACE_ROOT/scripts/manager/configure-bastion-mailu-postfix.sh" \
  --bastion-ip "$bastion_ip" \
  --bastion-ssh-host "$bastion_ssh_host" \
  --bastion-ssh-port "$bastion_ssh_port" \
  --bastion-ssh-user "$bastion_ssh_user" \
  --ssh-key-file "$ssh_key_file" \
  --mail-domain "$mail_domain" \
  --mail-hostname "$mail_hostname" \
  --mailu-front-address "$mailu_front_address" \
  --mailu-front-port 25 \
  --relay-listen-address "$mailu_relay_host" \
  --relay-listen-port 2525 \
  --relay-username "$relay_username" \
  --relay-secret-file "$relay_secret_file" \
  --cluster-id "$cluster_id"

verify_bastion_mailu_path "$bastion_ssh_host" "$bastion_ssh_port" "$bastion_ssh_user" "$ssh_key_file" "$mailu_front_address" 25 "$mailu_relay_host"
verify_mailu_relay_egress_path "$mailu_relay_host" 2525

admin_pod="$(resolve_admin_pod)"
[[ -n "$admin_pod" ]] || fail "Could not find a running Mailu admin pod"

log "Ensuring Mailu domain and DKIM"
dns_export_json="$(kubectl -n mailu exec "$admin_pod" -- flask mailu config-export --dns --json domain 2>/dev/null || true)"
dkim_record_json="$(printf '%s' "$dns_export_json" | extract_dkim_from_export)"
if [[ -z "$dkim_record_json" || "$dkim_record_json" == "null" ]]; then
  kubectl -n mailu exec "$admin_pod" -- flask mailu domain "$mail_domain" >/dev/null 2>&1 || true
  cat <<EOF | kubectl -n mailu exec -i "$admin_pod" -- flask mailu config-import --update - >/dev/null
domain:
  - name: ${mail_domain}
    dkim_key: -generate-
EOF
  dns_export_json="$(kubectl -n mailu exec "$admin_pod" -- flask mailu config-export --dns --json domain)"
  dkim_record_json="$(printf '%s' "$dns_export_json" | extract_dkim_from_export)"
fi

[[ -n "$dkim_record_json" && "$dkim_record_json" != "null" ]] || fail "Mailu did not export a structured DKIM DNS record"
dkim_txt_name="$(jq -r '.name // empty' <<<"$dkim_record_json")"
dkim_value="$(jq -r '.value // empty' <<<"$dkim_record_json")"
[[ -n "$dkim_txt_name" && -n "$dkim_value" ]] || fail "Mailu DKIM DNS export is missing name or value"
if [[ "$dkim_txt_name" != *"$mail_domain" ]]; then
  dkim_txt_name="${dkim_txt_name}.${mail_domain}"
fi
dkim_selector="${dkim_txt_name%%._domainkey.*}"

log "Applying Mailu DNS records"
apply_mail_dns_records "$mail_domain" "$mail_hostname" "$bastion_ip" "$dkim_txt_name" "$dkim_value" "$dmarc_policy" "$dmarc_rua_localpart"

if [[ "$bastion_provider" == "hetzner" && -n "$hcloud_token" ]]; then
  log "Configuring Hetzner PTR/rDNS for ${mail_hostname}"
  HCLOUD_TOKEN="$hcloud_token" \
    python3 "$WORKSPACE_ROOT/scripts/manager/ensure-hetzner-rdns.py" \
    --server-name "$server_name" \
    --fallback-server-name "$legacy_server_name" \
    --ip "$bastion_ip" \
    --ptr "$mail_hostname"
  rdns_status="configured"
  log "PTR/rDNS configured: ${bastion_ip} -> ${mail_hostname}"
fi

register_mailu_authentik_app "$mail_domain"

log "Syncing existing Authentik users to Mailu"
authentik_ensure_token
authentik_setup_forward
sync_mailu_mailboxes "$mail_domain" "$(jq -r '."api-token"' "$runtime_secret_file")"
log "Mailu mailbox sync complete"

dmarc_txt_value="v=DMARC1; p=${dmarc_policy}; rua=mailto:${dmarc_rua_localpart}@${mail_domain}; adkim=s; aspf=s"
jq -n \
  --arg mail_domain "$mail_domain" \
  --arg mail_hostname "$mail_hostname" \
  --arg dkim_selector "$dkim_selector" \
  --arg dkim_txt_name "$dkim_txt_name" \
  --arg dkim_txt_value "$dkim_value" \
  --arg spf_txt_name "$mail_domain" \
  --arg spf_txt_value "v=spf1 mx -all" \
  --arg dmarc_txt_name "_dmarc.${mail_domain}" \
  --arg dmarc_txt_value "$dmarc_txt_value" \
  --arg mx_name "$mail_domain" \
  --arg mx_value "10 ${mail_hostname}." \
  '{
    mail_domain: $mail_domain,
    mail_hostname: $mail_hostname,
    dkim_selector: $dkim_selector,
    dkim_txt_name: $dkim_txt_name,
    dkim_txt_value: $dkim_txt_value,
    spf_txt_name: $spf_txt_name,
    spf_txt_value: $spf_txt_value,
    dmarc_txt_name: $dmarc_txt_name,
    dmarc_txt_value: $dmarc_txt_value,
    mx_name: $mx_name,
    mx_value: $mx_value
  }' >"$dns_secret_file"
chmod 600 "$dns_secret_file"

bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
  --secret-name "mailu-dns" \
  --json-file "$dns_secret_file" \
  --required-keys "mail_domain,mail_hostname,dkim_selector,dkim_txt_name,dkim_txt_value,spf_txt_name,spf_txt_value,dmarc_txt_name,dmarc_txt_value,mx_name,mx_value"

bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "mailu" \
  --service-domain "$mail_hostname" \
  --service-path /

if [[ "$rdns_status" == "configured" ]]; then
  log "Mailu installed. PTR/rDNS configured: ${ptr_required}"
else
  log "Mailu installed. Create/verify PTR manually: ${ptr_required}"
fi
log "Run an external deliverability/open-relay check before using this for production mail."

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg mail_domain "$mail_domain" \
    --arg mail_hostname "$mail_hostname" \
    --arg admin_url "$admin_url" \
    --arg webmail_url "$webmail_url" \
    --arg ptr_required "$ptr_required" \
    --arg rdns_status "$rdns_status" \
    --arg bastion_postfix_status "configured" \
    --arg mailu_chart_version "2.7.1" \
    --arg mailu_app_version "2024.06.51" \
    --arg mailu_relay_host "$mailu_relay_host" \
    --arg mailu_storage_node "$mailu_storage_node" \
    --argjson dns_records_created '["A","MX","SPF","DMARC","DKIM"]' \
    '{
      mail_domain: $mail_domain,
      mail_hostname: $mail_hostname,
      admin_url: $admin_url,
      webmail_url: $webmail_url,
      dns_records_created: $dns_records_created,
      ptr_required: $ptr_required,
      rdns_status: $rdns_status,
      bastion_postfix_status: $bastion_postfix_status,
      mailu_chart_version: $mailu_chart_version,
      mailu_app_version: $mailu_app_version,
      mailu_relay_host: $mailu_relay_host,
      mailu_storage_node: $mailu_storage_node
    }' >"$STEP_RESULT_FILE"
fi
