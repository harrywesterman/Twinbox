#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TWINBOX_BOOTSTRAP_DIR="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
OPENBAO_GLOBAL_SECRETS_DIR="${OPENBAO_GLOBAL_SECRETS_DIR:-${TWINBOX_BOOTSTRAP_DIR}/secrets/global}"
OPENBAO_SEAL_DIR="${OPENBAO_SEAL_DIR:-${TWINBOX_BOOTSTRAP_DIR}/openbao/seal}"
OPENBAO_INIT_DIR="${OPENBAO_INIT_DIR:-${TWINBOX_BOOTSTRAP_DIR}/openbao/init}"
PROXMOX_SEED_FILE="${PROXMOX_SEED_FILE:-${OPENBAO_GLOBAL_SECRETS_DIR}/proxmox.json}"
TRAEFIK_DASHBOARD_SEED_FILE="${TRAEFIK_DASHBOARD_SEED_FILE:-${OPENBAO_GLOBAL_SECRETS_DIR}/traefik-dashboard.json}"
OPENBAO_SEAL_KEY_FILE="${OPENBAO_SEAL_KEY_FILE:-${OPENBAO_SEAL_DIR}/current.key}"
OPENBAO_SEAL_KEY_ID_FILE="${OPENBAO_SEAL_KEY_ID_FILE:-${OPENBAO_SEAL_DIR}/current-key-id}"
OPENBAO_INITIALIZED_FILE="${OPENBAO_INITIALIZED_FILE:-${OPENBAO_INIT_DIR}/initialized.json}"
OPENBAO_ROOT_TOKEN_FILE="${OPENBAO_ROOT_TOKEN_FILE:-${OPENBAO_INIT_DIR}/root-token}"
OPENBAO_RECOVERY_KEYS_FILE="${OPENBAO_RECOVERY_KEYS_FILE:-${OPENBAO_INIT_DIR}/recovery-keys.json}"
OPENBAO_NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-external-secrets}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-twinbox-system}"
CLUSTER_SECRET_STORE_NAME="${CLUSTER_SECRET_STORE_NAME:-openbao}"
EXTERNAL_SECRET_NAME="${EXTERNAL_SECRET_NAME:-proxmox-bootstrap}"
TARGET_SECRET_NAME="${TARGET_SECRET_NAME:-proxmox-bootstrap}"
OPENBAO_VALUES_FILE="${OPENBAO_VALUES_FILE:-${WORKSPACE_ROOT}/gitops/values/openbao.yaml}"
OPENBAO_VALUES_TEMPLATE="${OPENBAO_VALUES_TEMPLATE:-${WORKSPACE_ROOT}/gitops/values/openbao.yaml.template}"

openbao_log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

openbao_fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

openbao_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || openbao_fail "Missing required command: $1"
}

openbao_ensure_dir() {
  mkdir -p "$1"
}

openbao_read_json_field() {
  local file="$1"
  local field="$2"
  jq -r "$field" "$file"
}

openbao_require_json_field() {
  local file="$1"
  local field="$2"
  local value
  value="$(openbao_read_json_field "$file" "$field")"
  [[ -n "$value" && "$value" != "null" ]] || openbao_fail "Required field ${field} missing or empty in ${file}"
  printf '%s\n' "$value"
}

openbao_seed_management_bootstrap_files() {
  openbao_ensure_dir "$OPENBAO_GLOBAL_SECRETS_DIR"
  openbao_ensure_dir "$OPENBAO_SEAL_DIR"
  openbao_ensure_dir "$OPENBAO_INIT_DIR"

  if [[ ! -s "$PROXMOX_SEED_FILE" ]]; then
    local proxmox_host="${PROXMOX_HOST:-}"
    local proxmox_port="${PROXMOX_PORT:-8006}"
    local proxmox_user="${PROXMOX_USER:-}"
    local proxmox_password="${PROXMOX_PASSWORD:-${TF_VAR_proxmox_password:-}}"

    [[ -n "$proxmox_host" ]] || openbao_fail "PROXMOX_HOST is required to seed ${PROXMOX_SEED_FILE}"
    [[ -n "$proxmox_user" ]] || openbao_fail "PROXMOX_USER is required to seed ${PROXMOX_SEED_FILE}"
    [[ -n "$proxmox_password" ]] || openbao_fail "PROXMOX_PASSWORD is required to seed ${PROXMOX_SEED_FILE}"

    jq -n \
      --arg username "$proxmox_user" \
      --arg password "$proxmox_password" \
      --arg host "$proxmox_host" \
      --arg port "$proxmox_port" \
      --arg endpoint "https://${proxmox_host}:${proxmox_port}" \
      '{
        username: $username,
        password: $password,
        host: $host,
        port: $port,
        endpoint: $endpoint
      }' >"$PROXMOX_SEED_FILE"
    chmod 0600 "$PROXMOX_SEED_FILE"
    openbao_log "Seeded ${PROXMOX_SEED_FILE}"
  fi

  if [[ ! -s "$TRAEFIK_DASHBOARD_SEED_FILE" ]]; then
    local traefik_username="${TRAEFIK_DASHBOARD_USERNAME:-admin}"
    local traefik_password="${TRAEFIK_DASHBOARD_PASSWORD:-$(openssl rand -hex 16)}"
    local traefik_users
    traefik_users="${traefik_username}:$(openssl passwd -apr1 "$traefik_password")"

    jq -n \
      --arg username "$traefik_username" \
      --arg password "$traefik_password" \
      --arg users "$traefik_users" \
      '{
        username: $username,
        password: $password,
        users: $users
      }' >"$TRAEFIK_DASHBOARD_SEED_FILE"
    chmod 0600 "$TRAEFIK_DASHBOARD_SEED_FILE"
    openbao_log "Seeded ${TRAEFIK_DASHBOARD_SEED_FILE}"
  fi

  if [[ ! -s "$OPENBAO_SEAL_KEY_FILE" ]]; then
    openssl rand -out "$OPENBAO_SEAL_KEY_FILE" 32
    openbao_log "Seeded ${OPENBAO_SEAL_KEY_FILE}"
  fi
  chmod 0644 "$OPENBAO_SEAL_KEY_FILE"

  if [[ ! -s "$OPENBAO_SEAL_KEY_ID_FILE" ]]; then
    printf '%s\n' "${OPENBAO_SEAL_KEY_ID:-openbao-static-seal-v1}" >"$OPENBAO_SEAL_KEY_ID_FILE"
    openbao_log "Seeded ${OPENBAO_SEAL_KEY_ID_FILE}"
  fi
  chmod 0644 "$OPENBAO_SEAL_KEY_ID_FILE"
}

openbao_ensure_namespace() {
  local namespace="${1:-$OPENBAO_NAMESPACE}"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

openbao_seed_release_secret() {
  local seal_key_source="$OPENBAO_SEAL_KEY_FILE"
  local normalized tmp_key_file
  normalized="$(tr -d '[:space:]' <"$OPENBAO_SEAL_KEY_FILE" | tr '[:upper:]' '[:lower:]')"

  if [[ "$normalized" =~ ^[0-9a-f]{64}$ ]]; then
    tmp_key_file="$(mktemp "${TMPDIR:-/tmp}/openbao-seal-key-XXXXXX")"
    trap 'rm -f "$tmp_key_file"' RETURN
    printf '%b' "$(printf '%s' "$normalized" | sed 's/../\\x&/g')" >"$tmp_key_file"
    chmod 0600 "$tmp_key_file"
    seal_key_source="$tmp_key_file"
  fi

  kubectl create secret generic openbao-static-seal \
    --namespace "$OPENBAO_NAMESPACE" \
    --from-file=current.key="$seal_key_source" \
    --from-file=current-key-id="$OPENBAO_SEAL_KEY_ID_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

openbao_render_values_file() {
  local seal_key_id
  seal_key_id="$(tr -d '\r\n' <"$OPENBAO_SEAL_KEY_ID_FILE")"
  local replicas="${OPENBAO_REPLICAS:-1}"

  cat >"$OPENBAO_VALUES_FILE" <<EOF
global:
  tlsDisable: true

injector:
  enabled: false

csi:
  enabled: false

ui:
  enabled: false

server:
  enabled: true
  ha:
    enabled: true
    replicas: ${replicas}
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = false

        listener "tcp" {
          tls_disable = 1
          address = "[::]:8200"
          cluster_address = "[::]:8201"
        }

        storage "raft" {
          path = "/openbao/data"

          retry_join {
            leader_api_addr = "http://openbao-active:8200"
          }
        }

        seal "static" {
          current_key_id = "${seal_key_id}"
          current_key = "file:///openbao/secrets/current.key"
        }

        service_registration "kubernetes" {}
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: longhorn-single
    accessMode: ReadWriteOnce
  volumes:
    - name: openbao-static-seal
      secret:
        secretName: openbao-static-seal
  volumeMounts:
    - name: openbao-static-seal
      mountPath: /openbao/secrets
      readOnly: true
EOF

  openbao_log "Rendered OpenBao values to ${OPENBAO_VALUES_FILE}"
}

openbao_wait_for_statefulset_ready() {
  local attempt=1
  local attempts=120

  while [[ "$attempt" -le "$attempts" ]]; do
    local statefulset_json ready_replicas replicas
    statefulset_json="$(kubectl get statefulset openbao -n "$OPENBAO_NAMESPACE" -o json 2>/dev/null || true)"
    ready_replicas="$(printf '%s' "$statefulset_json" | jq -r '.status.readyReplicas // 0' 2>/dev/null || printf '0')"
    replicas="$(printf '%s' "$statefulset_json" | jq -r '.spec.replicas // 0' 2>/dev/null || printf '0')"

    ready_replicas="${ready_replicas:-0}"
    replicas="${replicas:-0}"

    if [[ "$replicas" =~ ^[0-9]+$ ]] && [[ "$ready_replicas" =~ ^[0-9]+$ ]] && [[ "$replicas" -gt 0 ]] && [[ "$ready_replicas" -ge "$replicas" ]]; then
      return 0
    fi

    openbao_log "Waiting for OpenBao StatefulSet to become ready (${ready_replicas}/${replicas})"
    sleep 5
    attempt=$((attempt + 1))
  done

  openbao_fail "OpenBao StatefulSet never became ready"
}

openbao_wait_for_server_pod() {
  local attempt=1
  local attempts=120

  while [[ "$attempt" -le "$attempts" ]]; do
    local pod=""
    pod="$(
      kubectl get pod -n "$OPENBAO_NAMESPACE" \
        -l app.kubernetes.io/instance=openbao,app.kubernetes.io/name=openbao \
        -o json 2>/dev/null | jq -r '
          .items[]
          | select(.status.phase == "Running")
          | select(any(.status.containerStatuses[]?; .name == "openbao" and .state.running != null))
          | .metadata.name
        ' | head -n 1
    )"
    if [[ -n "$pod" ]]; then
      printf '%s\n' "$pod"
      return 0
    fi

    openbao_log "Waiting for OpenBao pod to start running"
    sleep 5
    attempt=$((attempt + 1))
  done

  openbao_fail "OpenBao pod never started running"
}

openbao_exec() {
  local pod="$1"
  shift
  kubectl exec -i -n "$OPENBAO_NAMESPACE" "$pod" -- "$@"
}

openbao_wait_for_unsealed() {
  local pod="$1"
  local attempt=1
  local attempts=120

  while [[ "$attempt" -le "$attempts" ]]; do
    if openbao_exec "$pod" env BAO_ADDR=http://127.0.0.1:8200 sh -se <<'EOF' | grep -Eq '"sealed":[[:space:]]*false'
bao status -format=json
EOF
    then
      return 0
    fi

    openbao_log "Waiting for OpenBao to become unsealed"
    sleep 5
    attempt=$((attempt + 1))
  done

  openbao_fail "OpenBao never became unsealed"
}

openbao_initialize_if_needed() {
  local pod="$1"

  if [[ -f "$OPENBAO_INITIALIZED_FILE" ]]; then
    openbao_log "OpenBao already initialized; reusing bootstrap artifacts"
    openbao_wait_for_unsealed "$pod"
    return 0
  fi

  openbao_log "Initializing OpenBao"
  local init_json=""
  init_json="$(
    openbao_exec "$pod" env BAO_ADDR=http://127.0.0.1:8200 sh -se <<'EOF'
bao operator init -recovery-shares=0 -recovery-threshold=0 -format=json
EOF
  )"

  printf '%s\n' "$init_json" >"$OPENBAO_INITIALIZED_FILE"
  chmod 0600 "$OPENBAO_INITIALIZED_FILE"

  local root_token=""
  root_token="$(jq -r '.root_token // empty' "$OPENBAO_INITIALIZED_FILE")"
  [[ -n "$root_token" ]] || openbao_fail "OpenBao init output did not include a root token"

  printf '%s\n' "$root_token" >"$OPENBAO_ROOT_TOKEN_FILE"
  chmod 0600 "$OPENBAO_ROOT_TOKEN_FILE"

  jq -c '{
    keys_base64: (.keys_base64 // []),
    unseal_keys_b64: (.unseal_keys_b64 // []),
    recovery_keys_b64: (.recovery_keys_b64 // []),
    recovery_keys_hex: (.recovery_keys_hex // [])
  }' "$OPENBAO_INITIALIZED_FILE" >"$OPENBAO_RECOVERY_KEYS_FILE"
  chmod 0600 "$OPENBAO_RECOVERY_KEYS_FILE"

  openbao_wait_for_unsealed "$pod"
}

openbao_configure_auth_and_policy() {
  local pod="$1"
  local root_token
  root_token="$(tr -d '\r\n' <"$OPENBAO_ROOT_TOKEN_FILE")"

openbao_exec "$pod" env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" sh -se <<'EOF'
if ! bao secrets list -format=json | grep -q '"kv/"'; then
  bao secrets enable -path=kv kv-v2
fi

if ! bao auth list -format=json | grep -q '"kubernetes/"'; then
  bao auth enable -path=kubernetes kubernetes
fi
sleep 5

cat <<'POLICY' | bao policy write eso-read -
path "kv/data/twinbox/*" {
  capabilities = ["read"]
}

path "kv/metadata/twinbox/*" {
  capabilities = ["list", "read"]
}
POLICY

bao write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT_HTTPS:-${KUBERNETES_SERVICE_PORT:-443}}" \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-read \
  ttl=1h
EOF
}

openbao_seed_secret_paths() {
  local pod="$1"
  local root_token
  root_token="$(tr -d '\r\n' <"$OPENBAO_ROOT_TOKEN_FILE")"

  local proxmox_username proxmox_password proxmox_host proxmox_port proxmox_endpoint
  proxmox_username="$(openbao_require_json_field "$PROXMOX_SEED_FILE" '.username')"
  proxmox_password="$(openbao_require_json_field "$PROXMOX_SEED_FILE" '.password')"
  proxmox_host="$(openbao_require_json_field "$PROXMOX_SEED_FILE" '.host')"
  proxmox_port="$(openbao_require_json_field "$PROXMOX_SEED_FILE" '.port')"
  proxmox_endpoint="$(openbao_require_json_field "$PROXMOX_SEED_FILE" '.endpoint')"

  local traefik_username traefik_password traefik_users
  traefik_username="$(openbao_require_json_field "$TRAEFIK_DASHBOARD_SEED_FILE" '.username')"
  traefik_password="$(openbao_require_json_field "$TRAEFIK_DASHBOARD_SEED_FILE" '.password')"
  traefik_users="$(openbao_require_json_field "$TRAEFIK_DASHBOARD_SEED_FILE" '.users')"

  openbao_exec "$pod" env \
    BAO_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    PROXMOX_USERNAME="$proxmox_username" \
    PROXMOX_PASSWORD="$proxmox_password" \
    PROXMOX_HOST="$proxmox_host" \
    PROXMOX_PORT="$proxmox_port" \
    PROXMOX_ENDPOINT="$proxmox_endpoint" \
    sh -se <<'EOF'
bao kv put kv/twinbox/global/proxmox \
  username="$PROXMOX_USERNAME" \
  password="$PROXMOX_PASSWORD" \
  host="$PROXMOX_HOST" \
  port="$PROXMOX_PORT" \
  endpoint="$PROXMOX_ENDPOINT"
EOF

  openbao_exec "$pod" env \
    BAO_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="$root_token" \
    TRAEFIK_USERNAME="$traefik_username" \
    TRAEFIK_PASSWORD="$traefik_password" \
    TRAEFIK_USERS="$traefik_users" \
    sh -se <<'EOF'
bao kv put kv/twinbox/global/traefik-dashboard \
  username="$TRAEFIK_USERNAME" \
  password="$TRAEFIK_PASSWORD" \
  users="$TRAEFIK_USERS"
EOF
}

openbao_apply_cluster_secret_store() {
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${CLUSTER_SECRET_STORE_NAME}
spec:
  provider:
    vault:
      # External Secrets must talk to the active OpenBao endpoint so sealed
      # standby pods never receive login traffic.
      server: http://openbao-active.${OPENBAO_NAMESPACE}.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: external-secrets
          serviceAccountRef:
            name: external-secrets
            namespace: ${OPERATOR_NAMESPACE}
EOF
}

openbao_apply_bootstrap_external_secret() {
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${EXTERNAL_SECRET_NAME}
  namespace: ${TARGET_NAMESPACE}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ${CLUSTER_SECRET_STORE_NAME}
    kind: ClusterSecretStore
  target:
    name: ${TARGET_SECRET_NAME}
    creationPolicy: Owner
    deletionPolicy: Delete
  data:
    - secretKey: username
      remoteRef:
        key: twinbox/global/proxmox
        property: username
    - secretKey: password
      remoteRef:
        key: twinbox/global/proxmox
        property: password
    - secretKey: host
      remoteRef:
        key: twinbox/global/proxmox
        property: host
    - secretKey: port
      remoteRef:
        key: twinbox/global/proxmox
        property: port
    - secretKey: endpoint
      remoteRef:
        key: twinbox/global/proxmox
        property: endpoint
EOF
}

openbao_wait_for_external_secrets_webhook() {
  local attempt=1
  local attempts=60

  while [[ "$attempt" -le "$attempts" ]]; do
    local deployment_ready webhook_ready
    local deployment_json endpoint_json
    deployment_json="$(kubectl get deployment external-secrets-webhook -n "$OPERATOR_NAMESPACE" -o json 2>/dev/null || true)"
    endpoint_json="$(kubectl get endpoints external-secrets-webhook -n "$OPERATOR_NAMESPACE" -o json 2>/dev/null || true)"

    deployment_ready="$(
      printf '%s' "$deployment_json" | jq -r '((.status.availableReplicas // 0) > 0) and ((.status.readyReplicas // 0) > 0)' 2>/dev/null || true
    )"

    webhook_ready="$(
      printf '%s' "$endpoint_json" | jq -r '((.subsets // []) | map(.addresses // []) | add | length) > 0' 2>/dev/null || true
    )"

    if [[ "$deployment_ready" == "true" && "$webhook_ready" == "true" ]]; then
      return 0
    fi

    openbao_log "Waiting for External Secrets webhook to become ready"
    sleep 5
    attempt=$((attempt + 1))
  done

  openbao_fail "External Secrets webhook never became ready"
}

openbao_wait_for_secret() {
  local secret_name="$1"
  local namespace="$2"
  local attempt=1
  local attempts=120

  while [[ "$attempt" -le "$attempts" ]]; do
    if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
      return 0
    fi

    openbao_log "Waiting for Secret/${secret_name} in ${namespace}"
    sleep 5
    attempt=$((attempt + 1))
  done

  openbao_fail "Secret/${secret_name} did not appear in ${namespace}"
}

openbao_validate_json_keys() {
  local json_file="$1"
  shift

  local key=""
  for key in "$@"; do
    [[ -n "$key" ]] || continue
    jq -e --arg key "$key" '
      has($key) and .[$key] != null and (.[$key] | tostring | length) > 0
    ' "$json_file" >/dev/null || openbao_fail "Required key ${key} missing or empty in ${json_file}"
  done
}

openbao_wait_for_local_forward() {
  local forward_port="$1"
  local attempt=1
  local attempts=20

  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsS "http://127.0.0.1:${forward_port}/v1/sys/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  openbao_fail "OpenBao port-forward on 127.0.0.1:${forward_port} did not become ready"
}

openbao_sync_global_secret_file() {
  local secret_name="$1"
  local json_file="$2"
  shift 2
  local required_keys=("$@")

  [[ -n "$secret_name" ]] || openbao_fail "secret name is required"
  [[ -f "$json_file" ]] || openbao_fail "JSON secret file not found: ${json_file}"
  [[ -n "${KUBECONFIG_FILE:-}" ]] || openbao_fail "KUBECONFIG_FILE is required"
  [[ -f "${KUBECONFIG_FILE:-}" ]] || openbao_fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
  [[ -f "$OPENBAO_ROOT_TOKEN_FILE" ]] || openbao_fail "OpenBao root token file not found: ${OPENBAO_ROOT_TOKEN_FILE}"

  openbao_require_cmd jq
  openbao_require_cmd kubectl
  openbao_require_cmd curl

  export KUBECONFIG="$KUBECONFIG_FILE"
  openbao_validate_json_keys "$json_file" "${required_keys[@]}"

  local root_token=""
  root_token="$(tr -d '\r\n' <"$OPENBAO_ROOT_TOKEN_FILE")"
  [[ -n "$root_token" ]] || openbao_fail "OpenBao root token file is empty: ${OPENBAO_ROOT_TOKEN_FILE}"

  local payload=""
  payload="$(jq -c '{data: .}' "$json_file")"
  local forward_port="${OPENBAO_LOCAL_FORWARD_PORT:-18200}"
  local forward_log=""
  forward_log="$(mktemp "${TMPDIR:-/tmp}/openbao-port-forward-XXXXXX")"
  local port_forward_pid=""

  cleanup_openbao_port_forward() {
    if [[ -n "$port_forward_pid" ]]; then
      kill "$port_forward_pid" >/dev/null 2>&1 || true
      wait "$port_forward_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$forward_log"
  }

  trap cleanup_openbao_port_forward RETURN
  # Always forward through the active service rather than a single pod. OpenBao
  # pods in HA mode can answer `/v1/sys/health` with 429 when they are standby,
  # which would make a pod-specific readiness probe flaky even though the
  # cluster is healthy.
  kubectl -n "$OPENBAO_NAMESPACE" port-forward "svc/openbao-active" "${forward_port}:8200" >"$forward_log" 2>&1 &
  port_forward_pid="$!"
  openbao_wait_for_local_forward "$forward_port"

  curl -fsS \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Vault-Token: ${root_token}" \
    --data-binary "$payload" \
    "http://127.0.0.1:${forward_port}/v1/kv/data/twinbox/global/${secret_name}" >/dev/null

  openbao_log "Synced OpenBao secret twinbox/global/${secret_name} from ${json_file}"
}

openbao_read_global_secret_json() {
  local secret_name="$1"
  [[ -n "$secret_name" ]] || openbao_fail "secret name is required"
  [[ -f "$OPENBAO_ROOT_TOKEN_FILE" ]] || openbao_fail "OpenBao root token file not found: ${OPENBAO_ROOT_TOKEN_FILE}"

  local openbao_pod=""
  openbao_pod="$(openbao_wait_for_server_pod)"

  local root_token=""
  root_token="$(tr -d '\r\n' <"$OPENBAO_ROOT_TOKEN_FILE")"
  [[ -n "$root_token" ]] || openbao_fail "OpenBao root token file is empty: ${OPENBAO_ROOT_TOKEN_FILE}"

  openbao_exec "$openbao_pod" \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" sh -se <<EOF | jq -c '.data.data'
bao kv get -format=json kv/twinbox/global/${secret_name}
EOF
}

openbao_read_global_secret_field() {
  local secret_name="$1"
  local field="$2"
  [[ -n "$field" ]] || openbao_fail "field name is required"

  openbao_read_global_secret_json "$secret_name" | jq -r --arg field "$field" '.[$field] // empty'
}
