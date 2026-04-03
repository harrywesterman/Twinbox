#!/usr/bin/env bash
set -euo pipefail

: "${STEP_INPUTS_JSON:?missing STEP_INPUTS_JSON}"
: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"

export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# Parse cluster context
cluster_json="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -c '.cluster')"
cluster_id="$(printf '%s' "$cluster_json" | jq -r '.id')"
cluster_slug="$(printf '%s' "$cluster_json" | jq -r '.slug // .id')"
cluster_dns_domain="$(printf '%s' "$cluster_json" | jq -r '.dns_domain // empty')"

[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

if [[ -n "$cluster_dns_domain" ]]; then
  public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
  if [[ -n "$public_zone_name" ]]; then
    bash "$WORKSPACE_ROOT/scripts/manager/render-cluster-config-map.sh" \
      --zone-name "$public_zone_name"
  fi
fi

# Parse inputs
metallb_ip_range="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.metallb_ip_range')"
public_host="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.public_host')"
dyndns_provider="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dyndns_provider // empty')"
dyndns_token="$(printf '%s' "$STEP_INPUTS_JSON" | jq -r '.dyndns_token // empty')"

# Validate required inputs
[[ -n "$metallb_ip_range" ]] || fail "MetalLB IP range is required"
[[ -n "$public_host" ]] || fail "Public hostname is required"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting MetalLB ingress configuration for cluster: $cluster_id"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] IP range: $metallb_ip_range"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Public host: $public_host"
if [[ -n "$dyndns_provider" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DynDNS provider: $dyndns_provider"
fi

# Step 1: Deploy MetalLB
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deploying MetalLB"
if command -v kubectl &>/dev/null; then
  # Wait for Argo CD to be available
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD to be ready"
  for i in $(seq 1 30); do
    if kubectl get deployment argocd-server -n argocd &>/dev/null; then
      ready="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
      if [[ "$ready" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server is ready"
        break
      fi
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done

  # Apply the MetalLB application
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying MetalLB application"
  kubectl apply -f "$WORKSPACE_ROOT/gitops/apps/metallb.yaml" 2>/dev/null || true

  # Wait for MetalLB to be ready
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for MetalLB controller"
  for i in $(seq 1 60); do
    if kubectl get deployment metallb-controller -n metallb-system &>/dev/null; then
      ready="$(kubectl get deployment metallb-controller -n metallb-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
      if [[ "$ready" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MetalLB controller is ready"
        break
      fi
    fi
    sleep 5
  done

  # Step 2: Create IPAddressPool
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating MetalLB IPAddressPool"
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
    - "${metallb_ip_range}"
EOF

  # Step 3: Create L2Advertisement
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating L2Advertisement"
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default
EOF

  # Step 4: Update Traefik service to LoadBalancer
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updating Traefik service to LoadBalancer"
  kubectl patch service traefik -n traefik --type merge -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true

  # Wait for Traefik to get an external IP
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Traefik external IP"
  traefik_ip=""
  for i in $(seq 1 30); do
    traefik_ip="$(kubectl get service traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")"
    if [[ -n "$traefik_ip" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Traefik external IP: $traefik_ip"
      break
    fi
    sleep 5
  done
fi

# Step 5: Store credentials as global secret
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Writing MetalLB credentials to secrets"
secrets_dir="/opt/twinbox/bootstrap/secrets/global"
mkdir -p "$secrets_dir"

cat > "$secrets_dir/metallb-ingress-${cluster_id}.json" <<EOF
{
  "METALLB_IP_RANGE": "$metallb_ip_range",
  "PUBLIC_HOST": "$public_host",
  "DYNDNS_PROVIDER": "${dyndns_provider:-}",
  "DYNDNS_TOKEN": "${dyndns_token:-}",
  "CLUSTER_ID": "$cluster_id"
}
EOF

chmod 600 "$secrets_dir/metallb-ingress-${cluster_id}.json"

# Sync to OpenBao
if [[ -f "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing MetalLB credentials to OpenBao"
  bash "$WORKSPACE_ROOT/scripts/manager/sync-openbao-global-secret.sh" \
    --secret-name "metallb-ingress" \
    --json-file "$secrets_dir/metallb-ingress-${cluster_id}.json" \
    --required-keys "METALLB_IP_RANGE,PUBLIC_HOST"
fi

# Step 6: Configure Let's Encrypt for Traefik
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring Let's Encrypt certResolver for Traefik"
if command -v kubectl &>/dev/null; then
  # Update Traefik values to enable certResolver
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: traefik-letsencrypt-config
  namespace: traefik
data:
  certResolvers.yaml: |
    certificatesResolvers:
      letsencrypt:
        acme:
          email: admin@${public_host#*.}
          storage: /data/acme.json
          httpChallenge:
            entryPoint: web
EOF

  # Patch Traefik deployment to mount the cert resolver config
  kubectl patch deployment traefik -n traefik --type merge -p '{
    "spec": {
      "template": {
        "spec": {
          "containers": [{
            "name": "traefik",
            "args": [
              "--entrypoints.web.address=:8000",
              "--entrypoints.websecure.address=:8443",
              "--entrypoints.web.http.redirections.entryPoint.to=websecure",
              "--entrypoints.web.http.redirections.entryPoint.scheme=https",
              "--entrypoints.websecure.http.tls.certresolver=letsencrypt",
              "--certificatesresolvers.letsencrypt.acme.email=admin@'"${public_host#*.}"'",
              "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json",
              "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
            ],
            "volumeMounts": [{
              "name": "acme-data",
              "mountPath": "/data"
            }]
          }],
          "volumes": [{
            "name": "acme-data",
            "persistentVolumeClaim": {
              "claimName": "traefik-acme-data"
            }
          }]
        }
      }
    }
  }' 2>/dev/null || true

  # Create PVC for ACME data
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: traefik-acme-data
  namespace: traefik
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 100Mi
EOF
fi

# Step 7: Print port forwarding instructions
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] IMPORTANT: Configure port forwarding on your router"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Forward these ports to the MetalLB IP assigned to Traefik:"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   - Port 80  (HTTP, for Let's Encrypt challenges)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')]   - Port 443 (HTTPS, for secure traffic)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo ""

# Store ingress strategy in cluster state
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Recording ingress strategy as metallb"
if [[ -f "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" ]]; then
  tmp_file="$(mktemp)"
  jq '.ingress_strategy = "metallb"' "$MANAGER_DATA_DIR/clusters/${cluster_id}.json" > "$tmp_file"
  mv "$tmp_file" "$MANAGER_DATA_DIR/clusters/${cluster_id}.json"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] MetalLB ingress configuration complete"

# Write result
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  cat > "$STEP_RESULT_FILE" <<EOF
{
  "status": "succeeded",
  "outputs": {
    "ingress_strategy": "metallb",
    "metallb_ip_range": "$metallb_ip_range",
    "public_host": "$public_host",
    "dyndns_provider": "${dyndns_provider:-}",
    "cluster_id": "$cluster_id"
  }
}
EOF
fi
