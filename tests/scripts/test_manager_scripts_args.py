import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "bootstrap-talos.sh"
PROVISION_NODES_SCRIPT = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-nodes" / "run.sh"
MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "main.tf"
MODULE_OUTPUTS = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "outputs.tf"
INSTALL_SECRET_SYNC_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-secret-sync.sh"
ARGO_MANAGER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "install-argocd.sh"
ARGO_STEP_SCRIPT = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-argocd" / "run.sh"
ARGO_BOOTSTRAP_SCRIPT = REPO_ROOT / "gitops" / "install.sh"
WHOAMI_DEPLOYMENT = REPO_ROOT / "gitops" / "apps" / "whoami" / "deployment.yaml"
HEADLAMP_VALUES = REPO_ROOT / "gitops" / "values" / "headlamp.yaml"


def _apply_cluster_text() -> str:
    return APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")


def _bootstrap_text() -> str:
    return BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _module_text() -> str:
    return MODULE_MAIN.read_text(encoding="utf-8")


def _module_outputs_text() -> str:
    return MODULE_OUTPUTS.read_text(encoding="utf-8")


def _install_secret_sync_text() -> str:
    return INSTALL_SECRET_SYNC_SCRIPT.read_text(encoding="utf-8")


def _argo_manager_text() -> str:
    return ARGO_MANAGER_SCRIPT.read_text(encoding="utf-8")


def _argo_step_text() -> str:
    return ARGO_STEP_SCRIPT.read_text(encoding="utf-8")


def _argo_bootstrap_text() -> str:
    return ARGO_BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _whoami_deployment_text() -> str:
    return WHOAMI_DEPLOYMENT.read_text(encoding="utf-8")


def _headlamp_values_text() -> str:
    return HEADLAMP_VALUES.read_text(encoding="utf-8")


def test_apply_cluster_requires_proxmox_env():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(APPLY_CLUSTER_SCRIPT),
            "--cluster-id", "c1",
            "--name", "demo",
            "--controlplane-count", "1",
            "--worker-count", "1",
            "--cpu-cores", "2",
            "--memory-mb", "4096",
            "--disk-gb", "20",
            "--bridge", "vmbr0",
            "--start-vmid", "200",
            "--start-ip", "192.168.1.51",
            "--vip-ip", "192.168.1.50",
            "--node-prefix-length", "24",
            "--gateway-ip", "192.168.1.1",
            "--dns-servers", "1.1.1.1,1.0.0.1",
            "--dns-domain", "cluster.internal",
            "--proxmox-node", "pve",
            "--storage-pool", "local-lvm",
            "--file-datastore", "local",
            "--data-dir", td,
        ]
        env = {"PATH": os.environ.get("PATH", "")}
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
        assert proc.returncode != 0
        assert "Missing environment variable" in (proc.stdout + proc.stderr)


def test_collect_state_missing_cluster_file_fails():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(REPO_ROOT / "scripts/manager/collect-state.sh"),
            "--cluster-id", "missing",
            "--data-dir", td,
        ]
        proc = subprocess.run(cmd, env=os.environ.copy(), capture_output=True, text=True)
        assert proc.returncode != 0
        assert "cluster not found" in (proc.stdout + proc.stderr)


def test_apply_cluster_uses_pinned_defaults_and_tofu():
    text = _apply_cluster_text()
    assert 'source "$WORKSPACE_ROOT/config/pinned-defaults.sh"' in text
    assert 'command -v "$TOFU_BIN"' in text
    assert '"$TOFU_BIN" -chdir="$work_module_dir" init -input=false' in text
    assert '"$TOFU_BIN" -chdir="$work_module_dir" apply -input=false -auto-approve' in text
    assert 'command -v talosctl' in text
    assert 'export TF_IN_AUTOMATION=1' in text
    assert 'export NO_COLOR=1' in text
    assert 'command -v curl' in text
    assert 'resolve_talos_image_assets()' in text
    assert 'scripts/get-talos-image-factory.sh' in text
    assert 'PINNED_TALOS_IMAGE_SCHEMATIC' not in text
    assert '--preset "${TALOS_IMAGE_PRESET:-qemu-guest-agent}"' not in text
    assert 'TALOS_IMAGE_PRESET' in text
    assert 'talosctl apply-config' in text
    assert 'talosctl bootstrap' in text
    assert 'bootstrap_mode = "dhcp-first"' in text
    assert '"/image/default/"' not in text
    assert '!= "default"' not in text
    assert 'TALOS_IMAGE_FACTORY_URL:-' not in text
    assert 'TALOS_IMAGE_INSTALLER=' in text
    assert 'TALOS_IMAGE_DOWNLOAD_URL=' in text
    assert 'download_talos_image()' in text
    assert 'talos_image_local_path="$image_cache_dir/talos-${image_cache_key}.iso"' in text
    assert 'controlplane_ipv4_addresses.value' in text
    assert 'worker_ipv4_addresses.value' in text
    assert 'flatten_ipv4_candidates' in text or 'flatten | .[]' in text
    assert 'TF_VAR_proxmox_endpoint' in text
    assert 'TF_VAR_proxmox_username' in text
    assert 'TF_VAR_proxmox_password' in text
    assert '--arg proxmox_password "$PROXMOX_PASSWORD"' not in text
    assert 'proxmox_password: $proxmox_password' not in text


def test_apply_cluster_renders_dhcp_first_talos_flow_and_tracks_iac_paths():
    text = _apply_cluster_text()
    assert 'helper_output="$("$WORKSPACE_ROOT/scripts/get-talos-image-factory.sh"' in text
    assert '--preset "$talos_image_preset"' in text
    assert '--output shell' in text
    assert 'while IFS= read -r line; do' in text
    assert 'TALOS_IMAGE_INSTALLER=' in text
    assert 'TALOS_IMAGE_DOWNLOAD_URL=' in text
    assert 'cp -R "$MODULE_SOURCE/." "$work_module_dir/"' in text
    assert 'image_cache_key="${image_platform}-${image_arch}-${image_schematic}-${PINNED_TALOS_VERSION}"' in text
    assert 'Downloading Talos ISO' in text
    assert '--arg talos_image_local_path "$talos_image_local_path"' in text
    assert 'nodes: $nodes' in text
    assert 'planned_controlplane_ips' in text
    assert 'discovered_controlplane_ips' in text
    assert 'generate_talos_configs()' in text
    assert 'discover_node_ip()' in text
    assert 'Guest agent reported ${label} at ${candidate}' in text
    assert 'wait_for_talos_api()' in text
    assert 'bootstrap_cluster()' in text
    assert 'sync_user_kubeconfig()' in text
    assert 'sync_user_talosconfig()' in text
    assert 'talosctl config node "$default_node_ip"' in text
    assert 'talosctl config endpoint "$default_node_ip"' in text
    assert 'Reusing existing OpenTofu workspace at ${work_module_dir}' in text
    assert 'echo "    image: ${image_installer}"' in text
    assert 'image_installer="${line#TALOS_IMAGE_INSTALLER=}"' in text
    assert 'image_extensions=' not in text
    assert 'TALOS_IMAGE_EXTENSIONS=' not in text


def test_provision_nodes_step_returns_refs_not_kubeconfig_paths():
    text = PROVISION_NODES_SCRIPT.read_text(encoding="utf-8")
    assert 'secret_refs: .metadata.secret_refs' in text
    assert 'kubeconfig_path' not in text


def test_manager_worker_image_includes_talos_image_factory_helper():
    text = (REPO_ROOT / "manager-worker" / "Dockerfile").read_text(encoding="utf-8")
    assert 'ARG TALOSCTL_VERSION=v1.12.6' in text
    assert 'ARG BW_VERSION=v1.22.1' in text
    assert 'COPY lib ./lib' in text
    assert 'install -m 0755 /tmp/bw/bw /usr/local/bin/bw' in text
    assert 'COPY scripts/get-talos-image-factory.sh ./scripts/get-talos-image-factory.sh' in text
    assert 'RUN chmod +x ./scripts/get-talos-image-factory.sh' in text


def test_apply_cluster_uses_deterministic_mac_addresses_and_node_inventory():
    text = _apply_cluster_text()
    assert 'deterministic_mac()' in text
    assert "printf '52:54:%02x:%02x:%02x:%02x\\n'" in text
    assert 'type: $type' in text
    assert 'mac: $mac' in text
    assert '--file-datastore) FILE_DATASTORE="$2"; shift 2 ;;' in text
    assert 'file_datastore: $file_datastore' in text


def test_bootstrap_talos_uses_discovered_ips_and_records_runtime_state():
    text = _bootstrap_text()
    assert '(.discovered_controlplane_ips // .controlplane_ips // [])[]' in text
    assert '(.discovered_worker_ips // .worker_ips // [])[]' in text
    assert 'talosctl bootstrap' in text
    assert 'talosctl kubeconfig' in text
    assert 'qm guest cmd' not in text
    assert 'detach_all_vm_isos' not in text


def test_install_secret_sync_installs_eso_and_applies_secret_sync_manifests():
    text = _install_secret_sync_text()
    assert 'source "$WORKSPACE_ROOT/config/pinned-defaults.sh"' in text
    assert 'PINNED_EXTERNAL_SECRETS_CHART_VERSION' in text
    assert 'helm repo add external-secrets https://charts.external-secrets.io' in text
    assert 'helm upgrade --install external-secrets external-secrets/external-secrets' in text
    assert '--set-json "tolerations=${control_plane_tolerations}"' in text
    assert '--set-json "webhook.tolerations=${control_plane_tolerations}"' in text
    assert '--set-json "certController.tolerations=${control_plane_tolerations}"' in text
    assert 'node-role.kubernetes.io/control-plane' in text
    assert 'node-role.kubernetes.io/master' in text
    assert 'kubectl rollout status deployment/external-secrets' in text
    assert 'kind: SecretStore' in text
    assert 'kind: ExternalSecret' in text
    assert 'kind: NetworkPolicy' in text
    assert 'name: bitwarden-webhook-auth' in text
    assert 'external-secrets.io/type: webhook' in text
    assert 'Authorization: "Bearer {{ .auth.session }}"' in text
    assert 'secretRef:' in text
    assert 'name: bitwarden-webhook-auth' in text
    assert 'bitwarden-cli-allow-external-secrets' in text
    assert 'kubernetes.io/metadata.name: ${OPERATOR_NAMESPACE}' in text
    assert 'automountServiceAccountToken: false' in text
    assert 'tolerations:' in text
    assert 'node-role.kubernetes.io/control-plane' in text
    assert 'node-role.kubernetes.io/master' in text
    assert 'securityContext:' in text
    assert 'runAsNonRoot: true' in text
    assert 'runAsUser: 1000' in text
    assert 'runAsGroup: 1000' in text
    assert 'fsGroup: 1000' in text
    assert 'seccompProfile:' in text
    assert 'type: RuntimeDefault' in text
    assert 'allowPrivilegeEscalation: false' in text
    assert 'capabilities:' in text
    assert 'drop:' in text
    assert '- ALL' in text
    assert 'BITWARDENCLI_APPDATA_DIR' in text
    assert 'HOME' in text
    assert '/tmp/bitwarden-cli' in text
    assert 'emptyDir: {}' in text
    assert 'bw serve --hostname 0.0.0.0' in text
    assert 'bw_status="$(bw status | jq -r \'.status // "unauthenticated"\')"' in text
    assert 'if [[ "$bw_status" == "unauthenticated" ]]; then' in text
    assert 'bw sync --session "$session" >/dev/null' in text
    assert 'mktemp -d' not in text
    assert 'livenessProbe:' in text
    assert 'tcpSocket:' in text
    assert 'port: 8087' in text
    assert 'wget' not in text
    assert 'KUBECONFIG_FILE is required' in text


def test_argo_manager_script_requires_kubeconfig_and_calls_gitops_bootstrap():
    text = _argo_manager_text()
    assert 'Usage: $0 [--kube-api-server URL]' in text
    assert 'KUBE_API_SERVER=""' in text
    assert '--kube-api-server' in text
    assert 'Rewriting kubeconfig cluster' in text
    assert 'kubectl config set-cluster "$kube_cluster_name" --kubeconfig "$KUBECONFIG_FILE" --server "$KUBE_API_SERVER" >/dev/null' in text
    assert 'Bootstrapping Argo CD' in text
    assert 'bash "$WORKSPACE_ROOT/gitops/install.sh"' in text
    assert 'KUBECONFIG_FILE is required' in text


def test_argo_step_script_uses_workspace_root_for_manager_bootstrap():
    text = _argo_step_text()
    assert 'WORKSPACE_ROOT="${WORKSPACE_ROOT:-' in text
    assert 'discovered_controlplane_ips[0]' in text
    assert 'bash "$WORKSPACE_ROOT/scripts/manager/install-argocd.sh" --kube-api-server "https://${controlplane_ip}:6443"' in text


def test_argo_bootstrap_script_installs_argocd_and_applies_bootstrap_root_application():
    text = _argo_bootstrap_text()
    wait_section = text.split('local resources=(')[1].split('for resource in "${resources[@]}"; do')[0]
    assert 'Creating argocd namespace' in text
    assert 'Installing Argo CD' in text
    assert 'kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply --validate=false -f -' in text
    assert 'kubectl apply --server-side --force-conflicts --validate=false -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml' in text
    assert 'control_plane_tolerations' in text
    assert 'Patching statefulset/argocd-application-controller for control-plane tolerations' in text
    assert 'kubectl -n argocd patch' in text
    assert 'patch_argocd_workload_probes()' in text
    assert 'Patching ${resource} liveness probe for single-node bootstrap' in text
    assert '--type strategic -p' in text
    assert '"initialDelaySeconds":300' in text
    assert 'wait_for_available()' in text
    assert 'Waiting for ${resource} to become available' in text
    assert 'kubectl -n argocd wait --for=condition=Available "$resource" --timeout=900s' in text
    assert 'wait_for_statefulset_rollout()' in text
    assert 'kubectl -n argocd rollout status "$resource" --timeout=900s' in text
    assert 'wait_for_statefulset_rollout "statefulset/argocd-application-controller"' in text
    assert 'statefulset/argocd-application-controller' not in wait_section
    assert 'deployment/argocd-applicationset-controller' in text
    assert 'deployment/argocd-repo-server' in text
    assert 'statefulset/argocd-application-controller' in text
    assert 'Applying bootstrap root application' in text
    assert 'kubectl apply --validate=false -f "$WORKSPACE_ROOT/gitops/argocd/bootstrap/root.yaml"' in text


def test_bootstrap_apps_tolerate_single_node_control_plane():
    whoami_text = _whoami_deployment_text()
    headlamp_text = _headlamp_values_text()

    assert 'tolerations:' in whoami_text
    assert 'node-role.kubernetes.io/control-plane' in whoami_text
    assert 'node-role.kubernetes.io/master' in whoami_text
    assert 'tolerations:' in headlamp_text
    assert 'node-role.kubernetes.io/control-plane' in headlamp_text
    assert 'node-role.kubernetes.io/master' in headlamp_text


def test_talos_module_is_vm_only_and_keeps_planned_outputs():
    main_text = _module_text()
    outputs_text = _module_outputs_text()
    assert 'resource "proxmox_virtual_environment_vm" "node"' in main_text
    assert 'resource "proxmox_virtual_environment_file" "talos_nocloud"' in main_text
    assert 'content_type = "iso"' in main_text
    assert 'source_file {' in main_text
    assert 'path      = var.talos_image_local_path' in main_text
    assert 'file_name = "talos-${var.talos_image_cache_key}.iso"' in main_text
    assert 'machine   = "q35"' not in main_text
    assert 'boot_order = var.boot_from_disk ? ["virtio0"] : ["ide2", "virtio0"]' in main_text
    assert 'cdrom {' in main_text
    assert 'dynamic "cdrom"' not in main_text
    assert 'for_each = var.boot_from_disk ? [] : [1]' not in main_text
    assert 'file_id   = proxmox_virtual_environment_file.talos_nocloud.id' in main_text
    assert 'file_id      = proxmox_virtual_environment_file.talos_nocloud.id' not in main_text
    assert 'file_format  = "raw"' not in main_text
    assert 'agent {' in main_text
    assert 'wait_for_ip {' in main_text
    assert 'ipv4 = true' in main_text
    assert 'type = "std"' in main_text
    assert 'talos_machine_configuration_apply' not in main_text
    assert 'talos_machine_bootstrap' not in main_text
    assert 'talos_cluster_kubeconfig' not in main_text
    assert 'output "controlplane_vm_ids"' in outputs_text
    assert 'output "worker_vm_ids"' in outputs_text
    assert 'output "controlplane_ipv4_addresses"' in outputs_text
    assert 'output "worker_ipv4_addresses"' in outputs_text
    assert 'output "kubeconfig"' not in outputs_text
