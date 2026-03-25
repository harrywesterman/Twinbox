import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"
BOOTSTRAP_SCRIPT = REPO_ROOT / "scripts" / "manager" / "bootstrap-talos.sh"
MODULE_MAIN = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "main.tf"
MODULE_OUTPUTS = REPO_ROOT / "infra" / "opentofu" / "talos-proxmox" / "outputs.tf"


def _apply_cluster_text() -> str:
    return APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")


def _bootstrap_text() -> str:
    return BOOTSTRAP_SCRIPT.read_text(encoding="utf-8")


def _module_text() -> str:
    return MODULE_MAIN.read_text(encoding="utf-8")


def _module_outputs_text() -> str:
    return MODULE_OUTPUTS.read_text(encoding="utf-8")


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
    assert 'talosctl gen secrets -o "$talos_dir/secrets.yaml"' in text
    assert 'talosctl apply-config' in text
    assert 'talosctl bootstrap' in text
    assert 'bootstrap_mode = "dhcp-first"' in text
    assert '"/image/default/"' not in text
    assert '!= "default"' not in text
    assert 'TALOS_IMAGE_FACTORY_URL:-' not in text
    assert 'TALOS_IMAGE_INSTALLER=' in text
    assert 'TALOS_IMAGE_DOWNLOAD_URL=' in text
    assert 'download_talos_image()' in text
    assert 'talos_image_local_path="$talos_dir/talos-${image_cache_key}.iso"' in text
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
    assert 'Copied kubeconfig to ${target_kubeconfig}' in text
    assert 'Copied talosconfig to ${target_talosconfig}' in text
    assert 'talosctl config node "$default_node_ip"' in text
    assert 'talosctl config endpoint "$default_node_ip"' in text
    assert 'talos_config_dir' in text
    assert 'Reusing existing OpenTofu workspace at ${work_module_dir}' in text
    assert 'echo "    image: ${image_installer}"' in text
    assert 'image_installer="${line#TALOS_IMAGE_INSTALLER=}"' in text
    assert 'image_extensions=' not in text
    assert 'TALOS_IMAGE_EXTENSIONS=' not in text


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


def test_bootstrap_talos_uses_discovered_ips_and_persists_state():
    text = _bootstrap_text()
    assert '(.discovered_controlplane_ips // .controlplane_ips // [])[]' in text
    assert '(.discovered_worker_ips // .worker_ips // [])[]' in text
    assert 'talosctl bootstrap' in text
    assert 'talosctl kubeconfig' in text
    assert '.kubeconfig_path = $kubeconfig_path' in text
    assert 'qm guest cmd' not in text
    assert 'detach_all_vm_isos' not in text


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
    assert 'boot_order = ["ide2", "virtio0"]' in main_text
    assert 'cdrom {' in main_text
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
