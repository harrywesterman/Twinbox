#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: setup-dns-forwarder.sh --listen-ip <netbird-ip> --kubeconfig <path> [options]

Options:
  --listen-port <port>      UDP port exposed on the Management VM NetBird IP (default: 5354)
  --local-port <port>       Local TCP port used by kubectl port-forward (default: 1053)
  --namespace <namespace>   Kubernetes namespace for AdGuard (default: adguard)
  --service <name>          Kubernetes Service name for AdGuard DNS (default: adguard-dns)
  --service-port <port>     Kubernetes Service DNS port (default: 53)
EOF
  exit 1
}

LISTEN_IP=""
LISTEN_PORT="5354"
LOCAL_PORT="1053"
KUBECONFIG_PATH=""
NAMESPACE="adguard"
SERVICE_NAME="adguard-dns"
SERVICE_PORT="53"
CONTAINER_NAME="twinbox-dns-forwarder"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --listen-ip) LISTEN_IP="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --service) SERVICE_NAME="$2"; shift 2 ;;
    --service-port) SERVICE_PORT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$LISTEN_IP" ]] || usage
[[ -n "$KUBECONFIG_PATH" ]] || usage
[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "Kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to run the Twinbox DNS forwarder" >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "Docker daemon is not reachable" >&2
  exit 1
}

WORKER_IMAGE="${TWINBOX_DNS_FORWARDER_IMAGE:-}"
if [[ -z "$WORKER_IMAGE" ]]; then
  WORKER_IMAGE="$(docker inspect twinbox-manager-worker --format '{{.Config.Image}}' 2>/dev/null || true)"
fi
[[ -n "$WORKER_IMAGE" ]] || {
  echo "Could not determine manager-worker image for DNS forwarder" >&2
  exit 1
}

DATA_DIR="${MANAGER_DATA_DIR:-/data}"
HOST_DATA_DIR="${TWINBOX_HOST_MANAGER_DATA_DIR:-/opt/twinbox/manager-data}"
HOST_BOOTSTRAP_DIR="${TWINBOX_HOST_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
FORWARDER_DIR="${DATA_DIR}/dns-forwarder"
FORWARDER_KUBECONFIG="${FORWARDER_DIR}/kubeconfig"

mkdir -p "$FORWARDER_DIR"
cp "$KUBECONFIG_PATH" "$FORWARDER_KUBECONFIG"
chmod 600 "$FORWARDER_KUBECONFIG"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --network host \
  -e KUBECONFIG="$FORWARDER_KUBECONFIG" \
  -v "${HOST_DATA_DIR}:${DATA_DIR}" \
  -v "${HOST_BOOTSTRAP_DIR}:/opt/twinbox/bootstrap:ro" \
  --entrypoint bash \
  "$WORKER_IMAGE" \
  -lc "set -euo pipefail
kubectl -n '$NAMESPACE' port-forward --address 127.0.0.1 service/'$SERVICE_NAME' '$LOCAL_PORT':'$SERVICE_PORT' &
pf_pid=\$!
trap 'kill \"\$pf_pid\" 2>/dev/null || true; wait \"\$pf_pid\" 2>/dev/null || true' EXIT
for i in \$(seq 1 30); do
  if python3 - <<'PY' >/dev/null 2>&1
import socket
s = socket.create_connection(('127.0.0.1', $LOCAL_PORT), timeout=1)
s.close()
PY
  then
    break
  fi
  sleep 1
done
python3 /opt/twinbox/scripts/manager/dns-proxy.py --listen-host '$LISTEN_IP' --listen-port '$LISTEN_PORT' --upstream-host 127.0.0.1 --upstream-port '$LOCAL_PORT'
" >/dev/null

echo "Twinbox DNS forwarder is running on ${LISTEN_IP}:${LISTEN_PORT} via container ${CONTAINER_NAME}"
