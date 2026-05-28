#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
source "$WORKSPACE_ROOT/scripts/manager/cluster-public-zone.sh"
export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_id="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.id')"
cluster_slug="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.slug // .cluster.id')"
cluster_dns_domain="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.dns_domain // empty')"
[[ -n "$cluster_id" ]] || fail "Could not determine cluster ID from context"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing AdGuard Home DNS for cluster: $cluster_id"

# Read NetBird credentials from bastion secret
netbird_bastion_secret="/opt/twinbox/bootstrap/secrets/global/netbird-bastion-${cluster_id}.json"
[[ -f "$netbird_bastion_secret" ]] || fail "NetBird bastion secret not found at $netbird_bastion_secret"
netbird_management_url="$(jq -r '.NETBIRD_URL // empty' "$netbird_bastion_secret")"
netbird_token="$(jq -r '.NETBIRD_SETUP_TOKEN // empty' "$netbird_bastion_secret")"
[[ -n "$netbird_management_url" ]] || fail "NetBird management URL not found in bastion secret"
[[ -n "$netbird_token" ]] || fail "NetBird API token not found in bastion secret"

# --- Step 1: Apply Argo CD Application ---
if command -v kubectl >/dev/null 2>&1; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Argo CD server"
  for i in $(seq 1 30); do
    ready="$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    if [[ "${ready:-0}" -gt 0 ]]; then
      break
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Argo CD server not ready yet (attempt ${i}/30)"
    sleep 5
  done

  public_zone_name="$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")"
  adguard_rendered_manifest="$(mktemp)"
  sed "s/__ZONE_NAME__/${public_zone_name}/g" \
    "$WORKSPACE_ROOT/gitops/apps/adguard.yaml" >"$adguard_rendered_manifest"

  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$adguard_rendered_manifest" \
    --application "adguard" \
    --destination-namespace "argocd"
else
  fail "kubectl is required to install AdGuard Home"
fi

# --- Step 2: Wait for Deployment to be ready ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for AdGuard Deployment to be ready..."
for i in $(seq 1 60); do
  ready="$(kubectl get deployment adguard -n adguard -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
  desired="$(kubectl get deployment adguard -n adguard -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")"
  if [[ "${ready:-0}" -gt 0 && "$ready" -eq "$desired" && "$desired" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard Deployment is ready (${ready}/${desired} pods)"
    break
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard not ready yet (attempt ${i}/60, ${ready:-0}/${desired:-0} pods)"
  sleep 5
done

# --- Step 3: Read the AdGuard service ClusterIP ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reading AdGuard DNS service IP..."
adguard_service_ip="$(kubectl -n adguard get svc adguard-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ -z "$adguard_service_ip" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for ClusterIP assignment..."
  for i in $(seq 1 30); do
    adguard_service_ip="$(kubectl -n adguard get svc adguard-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    if [[ -n "$adguard_service_ip" ]]; then
      break
    fi
    sleep 2
  done
fi
[[ -n "$adguard_service_ip" ]] || fail "Could not determine AdGuard service ClusterIP"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DNS service IP: $adguard_service_ip"

# --- Step 4: Find the adguard_dns group ID ---
# Read from the netbird-network OpenTofu state (created by configure-netbird-ingress)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Looking up AdGuard DNS NetBird group..."
adguard_dns_group_id=""
admins_group_id=""
exit_node_users_group_id=""

network_workdir="$MANAGER_DATA_DIR/opentofu/netbird-network-${cluster_id}"
if [[ -d "$network_workdir" ]]; then
  adguard_dns_group_id="$(cd "$network_workdir" && tofu output -raw adguard_dns_group_id 2>/dev/null || true)"
  admins_group_id="$(cd "$network_workdir" && tofu output -raw admins_group_id 2>/dev/null || true)"
  exit_node_users_group_id="$(cd "$network_workdir" && tofu output -raw exit_node_users_group_id 2>/dev/null || true)"
fi

# Fallback: run OpenTofu from source
if [[ -z "$adguard_dns_group_id" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DNS group not found in state, applying OpenTofu..."
  service_cidr="$(kubectl -n kube-system get pod -l component=kube-apiserver -o json 2>/dev/null | jq -r '.items[0].spec.containers[0].command[] | select(startswith("--service-cluster-ip-range=")) | sub("^--service-cluster-ip-range="; "")' || true)"
  [[ -z "$service_cidr" ]] && service_cidr="10.96.0.0/12"

  network_workdir="$MANAGER_DATA_DIR/opentofu/netbird-network-${cluster_id}"
  mkdir -p "$network_workdir"
  cp -r "$WORKSPACE_ROOT/infra/opentofu/netbird-network/"* "$network_workdir/"

  cat > "$network_workdir/terraform.tfvars" <<EOF
netbird_token              = "$netbird_token"
netbird_management_url     = "$netbird_management_url"
cluster_id                 = "$cluster_id"
traefik_resource_address   = "traefik-netbird.traefik.svc.cluster.local"
service_cidrs              = ["$service_cidr"]
management_vm_ssh_port     = 22
management_vm_web_port     = 3000
management_vm_api_port     = 8080
EOF
  cd "$network_workdir"
  tofu init
  tofu apply -auto-approve
  adguard_dns_group_id="$(tofu output -raw adguard_dns_group_id)"
  admins_group_id="$(tofu output -raw admins_group_id)"
  exit_node_users_group_id="$(tofu output -raw exit_node_users_group_id)"
fi

[[ -n "$adguard_dns_group_id" ]] || fail "Could not determine AdGuard DNS NetBird group ID"
[[ -n "$admins_group_id" ]] || fail "Could not determine admins NetBird group ID"
[[ -n "$exit_node_users_group_id" ]] || fail "Could not determine exit-node-users NetBird group ID"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DNS group ID: $adguard_dns_group_id"

# --- Step 5: Configure the Management VM DNS forwarder ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Detecting Management VM NetBird IP..."
mgmt_netbird_status=""
mgmt_netbird_ip=""
if command -v netbird >/dev/null 2>&1; then
  mgmt_netbird_ip="$(netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 || true)"
  mgmt_netbird_status="$(netbird status 2>/dev/null || true)"
fi
if [[ -z "$mgmt_netbird_status" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  mgmt_netbird_ip="$(docker exec twinbox-netbird netbird status 2>/dev/null | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 || true)"
  mgmt_netbird_status="$(docker exec twinbox-netbird netbird status 2>/dev/null || true)"
fi
if [[ -z "$mgmt_netbird_ip" ]]; then
  mgmt_netbird_ip="$(printf '%s\n' "$mgmt_netbird_status" | awk -F': ' '/NetBird IP:/ {print $2; exit}' | cut -d/ -f1 2>/dev/null || true)"
fi
if [[ -z "$mgmt_netbird_ip" ]]; then
  mgmt_netbird_ip="$(python3 - "$netbird_management_url" "$netbird_token" "twinbox-mgmt-${cluster_slug}" <<'PY' 2>/dev/null || true
import json
import sys
import urllib.parse
import urllib.request

management_url, token, hostname = sys.argv[1], sys.argv[2], sys.argv[3]
base_url = management_url.rstrip("/")
if base_url.endswith("/api"):
    base_url = base_url[:-4]
url = f"{base_url}/api/peers?name={urllib.parse.quote(hostname)}"
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
with urllib.request.urlopen(req, timeout=10) as resp:
    peers = json.loads(resp.read().decode())
if isinstance(peers, dict):
    peers = peers.get("peers") or peers.get("items") or []
for peer in peers:
    if peer.get("name") == hostname and peer.get("ip"):
        print(str(peer["ip"]).split("/", 1)[0])
        break
PY
)"
fi
[[ -n "$mgmt_netbird_ip" ]] || fail "Could not determine Management VM NetBird IP"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Management VM NetBird IP: $mgmt_netbird_ip"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing DNS forwarder on Management VM..."
bash "$WORKSPACE_ROOT/scripts/manager/setup-dns-forwarder.sh" \
  --listen-ip "$mgmt_netbird_ip" \
  --listen-port 5354 \
  --kubeconfig "$KUBECONFIG_FILE" \
  --namespace adguard \
  --service adguard-dns \
  --service-port 53

# --- Step 6: Configure NetBird DNS nameserver group ---
# Point peers at the Management VM's NetBird IP so Android does not need a
# routed Kubernetes service CIDR in WireGuard AllowedIPs.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring NetBird DNS nameserver group..."
ns_result=$(python3 "$WORKSPACE_ROOT/scripts/manager/netbird-dns-nameserver.py" \
  --management-url "$netbird_management_url" \
  --token "$netbird_token" \
  --name "twinbox-${cluster_id}-adguard-dns" \
  --description "Twinbox AdGuard Home DNS" \
  --group-id "$adguard_dns_group_id" \
  --group-id "$admins_group_id" \
  --group-id "$exit_node_users_group_id" \
  --nameserver-ip "$mgmt_netbird_ip" \
  --nameserver-port 5354)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $ns_result"
ns_group_id="$(printf '%s' "$ns_result" | jq -r '.nameserver_group_id')"
[[ -n "$ns_group_id" ]] || fail "NetBird nameserver group was not created"

# --- Step 7: Verify in-cluster DNS ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Verifying in-cluster DNS..."
dns_check_output="$(kubectl -n adguard run adguard-dns-check --rm -i --restart=Never \
  --image=busybox:1.36 -- nslookup example.com "$adguard_service_ip" 2>&1 || true)"
if echo "$dns_check_output" | grep -q "Address"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS verification successful"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: DNS verification from pod failed. Output: $dns_check_output"
fi

# --- Step 8: Verify DNS through the Management VM forwarder ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Verifying DNS through Management VM forwarder..."
forwarder_check_output="$(python3 - "$mgmt_netbird_ip" <<'PY' 2>&1 || true
import socket
import sys

server = (sys.argv[1], 5354)
query = bytes.fromhex("123401000001000000000000076578616d706c6503636f6d0000010001")
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(5)
sock.sendto(query, server)
data, _ = sock.recvfrom(4096)
if len(data) < 12 or data[:2] != query[:2]:
    raise SystemExit("unexpected DNS response")
print("DNS forwarder verification successful")
PY
)"
if echo "$forwarder_check_output" | grep -q "successful"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS forwarder verification successful"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: DNS forwarder verification failed. Output: $forwarder_check_output"
fi

# --- Step 9: Register NetBird reverse proxy service ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Registering NetBird reverse proxy service for AdGuard..."
bash "$WORKSPACE_ROOT/scripts/manager/ensure-netbird-service.sh" \
  --service-name "adguard" \
  --service-domain "adguard.$(twinbox_public_zone_name "$cluster_slug" "$cluster_dns_domain")" \
  --service-path /

# --- Step 10: Write result ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard Home DNS installation complete"
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg cluster_id "$cluster_id" \
    --arg application "adguard" \
    --arg adguard_service_ip "$adguard_service_ip" \
    --arg management_vm_netbird_ip "$mgmt_netbird_ip" \
    --arg netbird_nameserver_group_id "$ns_group_id" \
    --arg netbird_adguard_dns_group_id "$adguard_dns_group_id" \
    '{
      status: $status,
      outputs: {
        cluster_id: $cluster_id,
        application: $application,
        adguard_service_ip: $adguard_service_ip,
        management_vm_netbird_ip: $management_vm_netbird_ip,
        netbird_nameserver_group_id: $netbird_nameserver_group_id,
        netbird_adguard_dns_group_id: $netbird_adguard_dns_group_id
      }
    }' >"$STEP_RESULT_FILE"
fi
