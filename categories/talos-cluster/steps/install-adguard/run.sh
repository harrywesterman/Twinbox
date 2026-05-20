#!/usr/bin/env bash
set -euo pipefail

: "${STEP_CONTEXT_JSON:?missing STEP_CONTEXT_JSON}"
: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${MANAGER_DATA_DIR:?missing MANAGER_DATA_DIR}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

cluster_id="$(printf '%s' "$STEP_CONTEXT_JSON" | jq -r '.cluster.id')"
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

  bash "$WORKSPACE_ROOT/scripts/manager/apply-argocd-application.sh" \
    --manifest "$WORKSPACE_ROOT/gitops/apps/adguard.yaml" \
    --application "adguard" \
    --destination-namespace "argocd"
else
  fail "kubectl is required to install AdGuard Home"
fi

# --- Step 2: Wait for DaemonSet to be ready ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for AdGuard DaemonSet to be ready..."
for i in $(seq 1 60); do
  ready="$(kubectl get daemonset adguard -n adguard -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")"
  desired="$(kubectl get daemonset adguard -n adguard -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")"
  if [[ "${ready:-0}" -gt 0 && "$ready" -eq "$desired" && "$desired" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DaemonSet is ready (${ready}/${desired} pods)"
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
# Try OpenTofu state output first, then fall back to running OpenTofu
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Looking up AdGuard DNS NetBird group..."
adguard_dns_group_id=""

# Check OpenTofu state for previous netbird-network run
tofu_state_dir="$MANAGER_DATA_DIR/clusters/${cluster_id}/iac"
if [[ -d "$tofu_state_dir" ]]; then
  adguard_dns_group_id="$(cd "$tofu_state_dir" && tofu output -raw adguard_dns_group_id 2>/dev/null || true)"
fi

# Fallback: run OpenTofu from source (like configure-netbird-ingress does)
if [[ -z "$adguard_dns_group_id" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DNS group not found in state, applying OpenTofu..."
  service_cidr="$(kubectl -n kube-system get pod -l component=kube-apiserver -o json 2>/dev/null | jq -r '.items[0].spec.containers[0].command[] | select(startswith("--service-cluster-ip-range=")) | sub("^--service-cluster-ip-range="; "")' || true)"
  [[ -z "$service_cidr" ]] && service_cidr="10.96.0.0/12"

  cd "$WORKSPACE_ROOT/infra/opentofu/netbird-network"
  TOFU_VARS_DIR="$MANAGER_DATA_DIR/clusters/${cluster_id}/iac"
  mkdir -p "$TOFU_VARS_DIR"

  cat > "$TOFU_VARS_DIR/terraform.tfvars" <<EOF
netbird_token              = "$netbird_token"
netbird_management_url     = "$netbird_management_url"
cluster_id                 = "$cluster_id"
traefik_resource_address   = "traefik-netbird.traefik.svc.cluster.local"
service_cidrs              = ["$service_cidr"]
management_vm_ssh_port     = 22
management_vm_web_port     = 3000
management_vm_api_port     = 8080
EOF
  cd "$TOFU_VARS_DIR"
  tofu init -from-module "$WORKSPACE_ROOT/infra/opentofu/netbird-network"
  tofu apply -auto-approve -var-file=terraform.tfvars
  adguard_dns_group_id="$(tofu output -raw adguard_dns_group_id)"
fi

[[ -n "$adguard_dns_group_id" ]] || fail "Could not determine AdGuard DNS NetBird group ID"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard DNS group ID: $adguard_dns_group_id"

# --- Step 5: Configure NetBird DNS nameserver group ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring NetBird DNS nameserver group..."
ns_result=$(python3 "$WORKSPACE_ROOT/scripts/manager/netbird-dns-nameserver.py" \
  --management-url "$netbird_management_url" \
  --token "$netbird_token" \
  --name "twinbox-${cluster_id}-adguard-dns" \
  --description "Twinbox AdGuard Home DNS" \
  --group-id "$adguard_dns_group_id" \
  --nameserver-ip "$adguard_service_ip")
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $ns_result"
ns_group_id="$(printf '%s' "$ns_result" | jq -r '.nameserver_group_id')"
[[ -n "$ns_group_id" ]] || fail "NetBird nameserver group was not created"

# --- Step 6: Verify in-cluster DNS ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Verifying in-cluster DNS..."
dns_check_output="$(kubectl -n adguard run adguard-dns-check --rm -i --restart=Never \
  --image=busybox:1.36 -- nslookup example.com "$adguard_service_ip" 2>&1 || true)"
if echo "$dns_check_output" | grep -q "Address"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DNS verification successful"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: DNS verification from pod failed. Output: $dns_check_output"
fi

# --- Step 7: Write result ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AdGuard Home DNS installation complete"
if [[ -n "${STEP_RESULT_FILE:-}" ]]; then
  jq -n \
    --arg status "succeeded" \
    --arg cluster_id "$cluster_id" \
    --arg application "adguard" \
    --arg adguard_service_ip "$adguard_service_ip" \
    --arg netbird_nameserver_group_id "$ns_group_id" \
    --arg netbird_adguard_dns_group_id "$adguard_dns_group_id" \
    '{
      status: $status,
      outputs: {
        cluster_id: $cluster_id,
        application: $application,
        adguard_service_ip: $adguard_service_ip,
        netbird_nameserver_group_id: $netbird_nameserver_group_id,
        netbird_adguard_dns_group_id: $netbird_adguard_dns_group_id
      }
    }' >"$STEP_RESULT_FILE"
fi
