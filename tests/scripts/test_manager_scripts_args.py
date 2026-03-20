import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"


def _apply_cluster_text() -> str:
    return APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")


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
    assert '"$TOFU_BIN" init -input=false' in text
    assert '"$TOFU_BIN" apply -input=false -auto-approve' in text
    assert '"$TOFU_BIN" output -json > "$outputs_file"' in text


def test_apply_cluster_renders_nocloud_and_tracks_iac_paths():
    text = _apply_cluster_text()
    assert 'image_url="${TALOS_IMAGE_FACTORY_URL:-https://factory.talos.dev/image/${image_schematic}/${PINNED_TALOS_VERSION}/nocloud-${image_arch}.raw.xz}"' in text
    assert 'cp -R "$MODULE_SOURCE/." "$work_module_dir/"' in text
    assert '"talos_image_cache_key": ${image_cache_key@Q}' in text
    assert '"nodes": ${nodes_json}' in text
    assert '.iac = {' in text
    assert 'kubeconfig_path = "$kubeconfig_file"' not in text
    assert '.kubeconfig_path =' in text
    assert 'jq -r \'.kubeconfig.value // empty\' "$outputs_file" > "$kubeconfig_file"' in text


def test_apply_cluster_uses_deterministic_mac_addresses_and_node_inventory():
    text = _apply_cluster_text()
    assert 'deterministic_mac()' in text
    assert "printf '52:54:%02x:%02x:%02x:%02x\\n'" in text
    assert 'type: $type' in text
    assert 'mac: $mac' in text
    assert '--file-datastore) FILE_DATASTORE="$2"; shift 2 ;;' in text
    assert '"file_datastore": ${FILE_DATASTORE@Q}' in text
