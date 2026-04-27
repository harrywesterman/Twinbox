#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

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

export KUBECONFIG
KUBECONFIG="$(resolve_kubeconfig_file)"

cluster_json="$(jq -c '.cluster // empty' <<<"$STEP_CONTEXT_JSON")"
cluster_id="$(jq -r '.id // empty' <<<"$cluster_json")"
cluster_slug="$(jq -r '.slug // empty' <<<"$cluster_json")"
cluster_dns_domain="$(jq -r '.dns_domain // empty' <<<"$cluster_json")"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"
[[ -n "$cluster_dns_domain" ]] || fail "Could not determine cluster DNS domain"

public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
[[ -n "$public_zone_name" ]] || fail "Could not determine public zone name"

log "Installing Coturn TURN server for cluster $cluster_id"

TURN_SECRET="${turn_secret:-$(openssl rand -hex 32)}"
REALM="turn.${public_zone_name}"

log "Creating namespace"
kubectl create namespace coturn --dry-run=client -o yaml | kubectl apply -f -

log "Creating TURN credentials secret"
kubectl -n coturn create secret generic coturn-credentials \
  --from-literal=shared-secret="$TURN_SECRET" \
  --from-literal=realm="$REALM" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creating Coturn configmap"
kubectl -n coturn create configmap coturn-config \
  --from-literal=turnserver.conf="
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
external-ip=0.0.0.0
realm=${REALM}
server-name=${REALM}
use-auth-secret
static-auth-secret=${TURN_SECRET}
allowed-origin=*
no-tlsv1
no-tlsv1_1
no-udp
no-tcp
cipher-list=ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES128:ECDH+3DES:DH+3DES:RSA+AES:RSA+3DES:!ADH:!AECDH:!MD5:!aNULL:!eNULL:!EXPORT
log-file=stdout
prod
stun-only
fingerprint
" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creating Coturn deployment"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coturn
  namespace: coturn
  labels:
    app: coturn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: coturn
  template:
    metadata:
      labels:
        app: coturn
    spec:
      containers:
      - name: coturn
        image: coturn/coturn:4.6.2
        imagePullPolicy: IfNotPresent
        args:
          - --config
          - /etc/coturn/turnserver.conf
        volumeMounts:
        - name: config
          mountPath: /etc/coturn
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
          privileged: true
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
      volumes:
      - name: config
        configMap:
          name: coturn-config
          items:
          - key: turnserver.conf
            path: turnserver.conf
EOF

log "Creating Coturn services"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: coturn
  namespace: coturn
spec:
  type: NodePort
  ports:
  - name: turn-tcp
    port: 3478
    targetPort: 3478
    protocol: TCP
    nodePort: 30478
  - name: turn-udp
    port: 3478
    targetPort: 3478
    protocol: UDP
    nodePort: 30478
  - name: turns-tcp
    port: 5349
    targetPort: 5349
    protocol: TCP
    nodePort: 30549
  selector:
    app: coturn
---
apiVersion: v1
kind: Service
metadata:
  name: coturn-internal
  namespace: coturn
spec:
  type: ClusterIP
  ports:
  - port: 3478
    targetPort: 3478
    name: turn
  selector:
    app: coturn
EOF

log "Waiting for Coturn to be ready"
kubectl -n coturn rollout status deployment/coturn --timeout=120s

log "Configuring Nextcloud Talk to use Coturn"
nextcloud_pod=$(kubectl -n nextcloud get pods -l app.kubernetes.io/name=nextcloud -o name 2>/dev/null | head -1 | sed 's|pods/||')
if [[ -n "$nextcloud_pod" ]]; then
  kubectl -n nextcloud exec "$nextcloud_pod" -c nextcloud -- su -s /bin/bash www-data -c \
    "php occ config:system:set turn_servers --value='[\"turn.${public_zone_name}:3478\"]' --type=json" 2>/dev/null || true
  
  kubectl -n nextcloud exec "$nextcloud_pod" -c nextcloud -- su -s /bin/bash www-data -c \
    "php occ config:system:set stun_servers --value='[\"turn.${public_zone_name}:3478\"]' --type=json" 2>/dev/null || true
fi

log "Coturn TURN server installed successfully!"
log "TURN Server: turn.${public_zone_name}:3478"
log "TLS Server: turn.${public_zone_name}:5349"
log "NodePort: 30478 (UDP/TCP), 30549 (TLS)"

if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg cluster_instance_id "$(printf '%s' "$cluster_json" | jq -r '.cluster_instance_id // empty')" \
    --arg turn_server "turn.${public_zone_name}:3478" \
    --arg tls_server "turn.${public_zone_name}:5349" \
    '{
      cluster_id: $cluster_id,
      cluster_instance_id: $cluster_instance_id,
      turn_server: $turn_server,
      tls_server: $tls_server
    }' >"$STEP_RESULT_FILE"
fi

log "Coturn installation complete"