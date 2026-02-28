import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CREATE_TALOS_SCRIPT = REPO_ROOT / "scripts" / "manager" / "create-talos-vms.sh"


def _create_talos_text() -> str:
    return CREATE_TALOS_SCRIPT.read_text(encoding="utf-8")


def test_create_talos_vms_requires_proxmox_env():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(REPO_ROOT / "scripts/manager/create-talos-vms.sh"),
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
            "--proxmox-node", "pve",
            "--storage-pool", "local-lvm",
            "--iso-storage", "local",
            "--talos-iso-file", "talos-v1.7.4.iso",
            "--data-dir", td,
        ]
        env = {"PATH": os.environ.get("PATH", "")}
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
        assert proc.returncode != 0
        assert "Missing environment variable" in (proc.stdout + proc.stderr)


def test_bootstrap_requires_controlplane_ips():
    with tempfile.TemporaryDirectory() as td:
        cmd = [
            "bash",
            str(REPO_ROOT / "scripts/manager/bootstrap-talos.sh"),
            "--cluster-id", "c1",
            "--name", "demo",
            "--vip-ip", "192.168.1.50",
            "--controlplane-ips", "",
            "--worker-ips", "",
            "--data-dir", td,
        ]
        proc = subprocess.run(cmd, env=os.environ.copy(), capture_output=True, text=True)
        assert proc.returncode != 0
        assert "At least one controlplane IP is required" in (proc.stdout + proc.stderr)


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


def test_create_talos_vms_sets_colorful_proxmox_tags():
    text = _create_talos_text()
    assert 'local role_tag="$3"' in text
    assert '--data-urlencode "tags=twinbox;talos;${role_tag};cluster-${CLUSTER_ID}"' in text
    assert 'create_vm "$current_vmid" "$vm_name" "controlplane"' in text
    assert 'create_vm "$current_vmid" "$vm_name" "worker"' in text


def test_create_talos_vms_fails_fast_on_proxmox_api_errors():
    text = _create_talos_text()
    assert "curl -k -sS --fail-with-body -X POST" in text
    assert 'fail "Proxmox API POST failed (${endpoint}): ${response}"' in text
    assert 'response_data=$(echo "$response" | jq -r \'.data // empty\')' in text
    assert 'fail "Proxmox API POST returned empty data (${endpoint}): ${response}"' in text
