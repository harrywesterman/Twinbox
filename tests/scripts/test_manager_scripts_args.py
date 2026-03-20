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
    assert 'talosctl gen secrets -o "$talos_dir/secrets.yaml"' in text
    assert 'talosctl apply-config' in text
    assert 'talosctl bootstrap' in text
    assert 'bootstrap_mode = "dhcp-first"' in text


def test_apply_cluster_renders_dhcp_first_talos_flow_and_tracks_iac_paths():
    text = _apply_cluster_text()
    assert 'image_url="${TALOS_IMAGE_FACTORY_URL:-https://factory.talos.dev/image/${image_schematic}/${PINNED_TALOS_VERSION}/nocloud-${image_arch}.raw.xz}"' in text
    assert 'cp -R "$MODULE_SOURCE/." "$work_module_dir/"' in text
    assert 'talos_image_cache_key: $talos_image_cache_key' in text
    assert 'nodes: $nodes' in text
    assert 'planned_controlplane_ips' in text
    assert 'discovered_controlplane_ips' in text
    assert 'generate_talos_configs()' in text
    assert 'discover_node_ip()' in text
    assert 'bootstrap_cluster()' in text
    assert 'talos_config_dir' in text


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
    assert 'talos_machine_configuration_apply' not in main_text
    assert 'talos_machine_bootstrap' not in main_text
    assert 'talos_cluster_kubeconfig' not in main_text
    assert 'output "controlplane_vm_ids"' in outputs_text
    assert 'output "worker_vm_ids"' in outputs_text
    assert 'output "kubeconfig"' not in outputs_text
