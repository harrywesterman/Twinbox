import json
import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RUN_SCRIPT = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "provision-nodes" / "run.sh"


def test_provision_nodes_uses_current_step_context_vm_node_map():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        scripts_dir = root / "scripts" / "manager"
        capture_file = data_dir / "captured-args.txt"

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        scripts_dir.mkdir(parents=True, exist_ok=True)

        # Stale runtime state from an older cluster generation.
        stale_cluster = {
            "id": "tst",
            "vm_node_map": {
                "cp-1": "old-a",
                "cp-2": "old-b",
                "worker-1": "old-c",
            },
        }
        (data_dir / "clusters" / "tst.json").write_text(json.dumps(stale_cluster), encoding="utf-8")

        fake_apply = scripts_dir / "apply-cluster.sh"
        fake_apply.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            'printf \'VM_NODE_MAP=%s\\n\' "${VM_NODE_MAP:-}" >> "$MANAGER_DATA_DIR/captured-env.txt"\n'
            'printf \'%s\\n\' "$@" > "$MANAGER_DATA_DIR/captured-args.txt"\n',
            encoding="utf-8",
        )
        fake_apply.chmod(0o755)

        cluster_payload = {
            "cluster": {
                "id": "tst",
                "name": "twinbox-tst",
                "controlplane_count": 2,
                "worker_count": 1,
                "cpu_cores": 2,
                "memory_mb": 4096,
                "disk_gb": 20,
                "bridge": "vmbr0",
                "start_vmid": 200,
                "start_ip": "192.168.1.51",
                "vip_ip": "192.168.1.50",
                "node_prefix_length": 24,
                "gateway_ip": "192.168.1.1",
                "dns_servers": ["1.1.1.1", "8.8.8.8"],
                "dns_domain": "cluster.internal",
                "vm_ip_map": {
                    "cp-1": "192.168.1.61",
                    "cp-2": "192.168.1.62",
                    "worker-1": "192.168.1.63",
                },
                "vm_node_map": {
                    "cp-1": "new-a",
                    "cp-2": "new-b",
                    "worker-1": "new-c",
                },
                "vm_size_map": {
                    "cp-1": {"cpu": 2, "memory_mb": 4096, "disk_gb": 20},
                    "cp-2": {"cpu": 2, "memory_mb": 6144, "disk_gb": 30},
                    "worker-1": {"cpu": 4, "memory_mb": 12288, "disk_gb": 80},
                },
                "vm_storage_map": {
                    "cp-1": "local-lvm",
                    "cp-2": "fast-zfs",
                    "worker-1": "shared-ceph",
                },
                "metadata": {
                    "proxmox_node": "pve",
                    "storage_pool": "local-lvm",
                    "file_datastore": "local",
                },
            }
        }

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["STEP_CONTEXT_JSON"] = json.dumps(cluster_payload)

        proc = subprocess.run(
            ["bash", str(RUN_SCRIPT)],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr
        assert capture_file.exists()
        env_capture = (data_dir / "captured-env.txt").read_text(encoding="utf-8")
        assert 'VM_NODE_MAP={"cp-1":"new-a","cp-2":"new-b","worker-1":"new-c"}' in env_capture

        args = capture_file.read_text(encoding="utf-8").splitlines()
        assert "--vm-node-map" in args
        vm_node_map_index = args.index("--vm-node-map") + 1
        assert json.loads(args[vm_node_map_index]) == {
            "cp-1": "new-a",
            "cp-2": "new-b",
            "worker-1": "new-c",
        }
        assert "--vm-ip-map" in args
        vm_ip_map_index = args.index("--vm-ip-map") + 1
        assert json.loads(args[vm_ip_map_index]) == {
            "cp-1": "192.168.1.61",
            "cp-2": "192.168.1.62",
            "worker-1": "192.168.1.63",
        }
        assert "--vm-storage-map" in args
        vm_storage_map_index = args.index("--vm-storage-map") + 1
        assert json.loads(args[vm_storage_map_index]) == {
            "cp-1": "local-lvm",
            "cp-2": "fast-zfs",
            "worker-1": "shared-ceph",
        }
        assert json.loads((data_dir / "clusters" / "tst.json").read_text(encoding="utf-8"))[
            "vm_node_map"
        ] == {
            "cp-1": "old-a",
            "cp-2": "old-b",
            "worker-1": "old-c",
        }
