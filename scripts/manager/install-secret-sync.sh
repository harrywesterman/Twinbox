#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --cluster-id ID [--operator-namespace NAME] [--bitwarden-namespace NAME] [--target-namespace NAME] [--login-store-name NAME] [--fields-store-name NAME] [--external-secret-name NAME] [--target-secret-name NAME]
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/config/pinned-defaults.sh"

OPERATOR_NAMESPACE="external-secrets"
BITWARDEN_NAMESPACE="bitwarden"
TARGET_NAMESPACE="twinbox-system"
LOGIN_STORE_NAME="bitwarden-login"
FIELDS_STORE_NAME="bitwarden-fields"
EXTERNAL_SECRET_NAME="proxmox-bootstrap"
TARGET_SECRET_NAME="proxmox-bootstrap"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --operator-namespace) OPERATOR_NAMESPACE="$2"; shift 2 ;;
    --bitwarden-namespace) BITWARDEN_NAMESPACE="$2"; shift 2 ;;
    --target-namespace) TARGET_NAMESPACE="$2"; shift 2 ;;
    --login-store-name) LOGIN_STORE_NAME="$2"; shift 2 ;;
    --fields-store-name) FIELDS_STORE_NAME="$2"; shift 2 ;;
    --external-secret-name) EXTERNAL_SECRET_NAME="$2"; shift 2 ;;
    --target-secret-name) TARGET_SECRET_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${CLUSTER_ID:-}" ]] || { usage; fail "cluster-id required"; }
[[ -n "${KUBECONFIG_FILE:-}" ]] || fail "KUBECONFIG_FILE is required"
[[ -f "${KUBECONFIG_FILE:-}" ]] || fail "kubeconfig not found at ${KUBECONFIG_FILE:-}"
[[ -n "${VAULTWARDEN_SERVER_URL:-}" ]] || fail "VAULTWARDEN_SERVER_URL is required"
[[ -n "${VAULTWARDEN_PASSWORD_FILE:-}" ]] || fail "VAULTWARDEN_PASSWORD_FILE is required"
[[ -n "${VAULTWARDEN_CLIENTID_FILE:-}" ]] || fail "VAULTWARDEN_CLIENTID_FILE is required"
[[ -n "${VAULTWARDEN_CLIENTSECRET_FILE:-}" ]] || fail "VAULTWARDEN_CLIENTSECRET_FILE is required"

require_cmd kubectl
require_cmd helm
require_cmd jq
require_cmd bw

export KUBECONFIG="$KUBECONFIG_FILE"

bitwarden_appdata_dir="${BITWARDENCLI_APPDATA_DIR:-${WORKSPACE_ROOT}/bootstrap/bw-runtime}"
mkdir -p "$bitwarden_appdata_dir"
cleanup() {
  :
}
trap cleanup EXIT

export BITWARDENCLI_APPDATA_DIR="$bitwarden_appdata_dir"
export BW_CLIENTID="$(tr -d '\r\n' < "$VAULTWARDEN_CLIENTID_FILE")"
export BW_CLIENTSECRET="$(tr -d '\r\n' < "$VAULTWARDEN_CLIENTSECRET_FILE")"

bw config server "$VAULTWARDEN_SERVER_URL" >/dev/null
bw_status="$(bw status | jq -r '.status // "unauthenticated"')"
if [[ "$bw_status" == "unauthenticated" ]]; then
  bw login --apikey >/dev/null
fi
session="$(bw unlock --passwordfile "$VAULTWARDEN_PASSWORD_FILE" --raw)"
bw sync --session "$session" >/dev/null

item_name="${VAULTWARDEN_ITEM_PREFIX:-twinbox}/global/proxmox"
item="$(bw list items --search "$item_name" --session "$session" | jq -c --arg name "$item_name" '.[] | select(.name == $name)')"
[[ -n "$item" ]] || fail "Vaultwarden item not found: ${item_name}"

proxmox_item_id="$(printf '%s' "$item" | jq -r '.id')"
[[ -n "$proxmox_item_id" && "$proxmox_item_id" != "null" ]] || fail "Vaultwarden item ID missing for ${item_name}"

chart_version="${PINNED_EXTERNAL_SECRETS_CHART_VERSION:-0.20.1}"
cli_password="$(tr -d '\r\n' < "$VAULTWARDEN_PASSWORD_FILE")"
cli_client_id="$(tr -d '\r\n' < "$VAULTWARDEN_CLIENTID_FILE")"
cli_client_secret="$(tr -d '\r\n' < "$VAULTWARDEN_CLIENTSECRET_FILE")"
cli_session="$session"
worker_image="ghcr.io/harrywesterman/twinbox-manager-worker:${TWINBOX_IMAGE_TAG:-latest}"
control_plane_tolerations='[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]'

log "Installing External Secrets Operator ${chart_version}"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "$OPERATOR_NAMESPACE" \
  --create-namespace \
  --version "$chart_version" \
  --set-json "tolerations=${control_plane_tolerations}" \
  --set-json "webhook.tolerations=${control_plane_tolerations}" \
  --set-json "certController.tolerations=${control_plane_tolerations}"

kubectl rollout status deployment/external-secrets -n "$OPERATOR_NAMESPACE" --timeout=180s

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${BITWARDEN_NAMESPACE}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${TARGET_NAMESPACE}
EOF

kubectl create secret generic bitwarden-cli \
  --namespace "$BITWARDEN_NAMESPACE" \
  --from-literal=BW_HOST="$VAULTWARDEN_SERVER_URL" \
  --from-literal=BW_PASSWORD="$cli_password" \
  --from-literal=BW_CLIENTID="$cli_client_id" \
  --from-literal=BW_CLIENTSECRET="$cli_client_secret" \
  --from-literal=BW_SESSION="$cli_session" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bitwarden-webhook-auth
  namespace: ${TARGET_NAMESPACE}
  labels:
    external-secrets.io/type: webhook
type: Opaque
stringData:
  session: ${cli_session}
EOF

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bitwarden-cli-allow-external-secrets
  namespace: ${BITWARDEN_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: bitwarden-cli
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${OPERATOR_NAMESPACE}
      ports:
        - protocol: TCP
          port: 8087
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bitwarden-cli
  namespace: ${BITWARDEN_NAMESPACE}
  labels:
    app.kubernetes.io/instance: bitwarden-cli
    app.kubernetes.io/name: bitwarden-cli
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/instance: bitwarden-cli
      app.kubernetes.io/name: bitwarden-cli
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: bitwarden-cli
        app.kubernetes.io/name: bitwarden-cli
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: bitwarden-cli
          image: ${worker_image}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          command:
            - /bin/bash
            - -lc
          args:
            - |
              set -euo pipefail
              bw config server "\${BW_HOST}"
              bw login --apikey >/dev/null
              bw unlock --passwordenv BW_PASSWORD >/dev/null
              exec bw serve --hostname 0.0.0.0
          env:
            - name: BITWARDENCLI_APPDATA_DIR
              value: /tmp/bitwarden-cli
            - name: HOME
              value: /tmp/bitwarden-cli
            - name: BW_HOST
              valueFrom:
                secretKeyRef:
                  name: bitwarden-cli
                  key: BW_HOST
            - name: BW_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: bitwarden-cli
                  key: BW_PASSWORD
            - name: BW_CLIENTID
              valueFrom:
                secretKeyRef:
                  name: bitwarden-cli
                  key: BW_CLIENTID
            - name: BW_CLIENTSECRET
              valueFrom:
                secretKeyRef:
                  name: bitwarden-cli
                  key: BW_CLIENTSECRET
            - name: BW_SESSION
              valueFrom:
                secretKeyRef:
                  name: bitwarden-cli
                  key: BW_SESSION
          ports:
            - name: http
              containerPort: 8087
              protocol: TCP
          livenessProbe:
            tcpSocket:
              port: 8087
            initialDelaySeconds: 20
            failureThreshold: 3
            timeoutSeconds: 1
            periodSeconds: 120
          readinessProbe:
            tcpSocket:
              port: 8087
            initialDelaySeconds: 20
            failureThreshold: 3
            timeoutSeconds: 1
            periodSeconds: 10
          startupProbe:
            tcpSocket:
              port: 8087
            initialDelaySeconds: 10
            failureThreshold: 30
            timeoutSeconds: 1
            periodSeconds: 5
          volumeMounts:
            - name: bitwarden-cli-appdata
              mountPath: /tmp/bitwarden-cli
      volumes:
        - name: bitwarden-cli-appdata
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: bitwarden-cli
  namespace: ${BITWARDEN_NAMESPACE}
  labels:
    app.kubernetes.io/instance: bitwarden-cli
    app.kubernetes.io/name: bitwarden-cli
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8087
      protocol: TCP
      targetPort: http
  selector:
    app.kubernetes.io/instance: bitwarden-cli
    app.kubernetes.io/name: bitwarden-cli
EOF

kubectl rollout status deployment/bitwarden-cli -n "$BITWARDEN_NAMESPACE" --timeout=180s

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: ${LOGIN_STORE_NAME}
  namespace: ${TARGET_NAMESPACE}
spec:
  provider:
    webhook:
      url: "http://bitwarden-cli.${BITWARDEN_NAMESPACE}.svc.cluster.local:8087/object/item/{{ .remoteRef.key }}"
      headers:
        Content-Type: application/json
        Authorization: "Bearer {{ .auth.session }}"
      secrets:
        - name: auth
          secretRef:
            name: bitwarden-webhook-auth
      result:
        jsonPath: "$.data.login.{{ .remoteRef.property }}"
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: ${FIELDS_STORE_NAME}
  namespace: ${TARGET_NAMESPACE}
spec:
  provider:
    webhook:
      url: "http://bitwarden-cli.${BITWARDEN_NAMESPACE}.svc.cluster.local:8087/object/item/{{ .remoteRef.key }}"
      headers:
        Authorization: "Bearer {{ .auth.session }}"
      secrets:
        - name: auth
          secretRef:
            name: bitwarden-webhook-auth
      result:
        jsonPath: "$.data.fields[?@.name==\"{{ .remoteRef.property }}\"].value"
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${EXTERNAL_SECRET_NAME}
  namespace: ${TARGET_NAMESPACE}
spec:
  refreshInterval: 1h
  target:
    name: ${TARGET_SECRET_NAME}
    creationPolicy: Owner
    deletionPolicy: Delete
  data:
    - secretKey: username
      sourceRef:
        storeRef:
          name: ${LOGIN_STORE_NAME}
          kind: SecretStore
      remoteRef:
        key: ${proxmox_item_id}
        property: username
    - secretKey: password
      sourceRef:
        storeRef:
          name: ${LOGIN_STORE_NAME}
          kind: SecretStore
      remoteRef:
        key: ${proxmox_item_id}
        property: password
    - secretKey: host
      sourceRef:
        storeRef:
          name: ${FIELDS_STORE_NAME}
          kind: SecretStore
      remoteRef:
        key: ${proxmox_item_id}
        property: host
    - secretKey: port
      sourceRef:
        storeRef:
          name: ${FIELDS_STORE_NAME}
          kind: SecretStore
      remoteRef:
        key: ${proxmox_item_id}
        property: port
    - secretKey: endpoint
      sourceRef:
        storeRef:
          name: ${FIELDS_STORE_NAME}
          kind: SecretStore
      remoteRef:
        key: ${proxmox_item_id}
        property: endpoint
EOF

kubectl wait --for=condition=Ready "externalsecret/${EXTERNAL_SECRET_NAME}" -n "$TARGET_NAMESPACE" --timeout=180s
kubectl get secret "$TARGET_SECRET_NAME" -n "$TARGET_NAMESPACE" >/dev/null

bw lock --session "$session" >/dev/null || true

log "External Secrets Operator installed and ${TARGET_SECRET_NAME} synced in ${TARGET_NAMESPACE}"
