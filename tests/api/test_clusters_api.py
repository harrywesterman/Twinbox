import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import request, error


def _find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_health(base_url, timeout=10):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with request.urlopen(f"{base_url}/api/health", timeout=1) as resp:
                if resp.status == 200:
                    return
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("manager-api did not become healthy in time")


def _post_json(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, json.loads(body)


def _get_json(url):
    req = request.Request(url, method="GET")
    try:
        with request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, json.loads(body)


def test_create_cluster_missing_required_fields():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            status, body = _post_json(f"http://127.0.0.1:{port}/api/clusters", {"name": "x"})
            assert status == 400
            assert "must be" in body["error"]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_create_cluster_enqueues_job_and_persists_files():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text("#!/bin/sh\necho '[]'\n", encoding="utf-8")
        vm_mock.chmod(0o755)
        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            payload = {
                "name": "demo",
                "controlplane_count": 1,
                "worker_count": 2,
                "cpu_cores": 2,
                "memory_mb": 4096,
                "disk_gb": 20,
                "bridge": "vmbr0",
                "start_vmid": 200,
                "vip_ip": "192.168.1.50",
                "start_ip": "192.168.1.51",
            }
            status, body = _post_json(f"http://127.0.0.1:{port}/api/clusters", payload)
            assert status == 202
            assert "cluster_id" in body
            assert "job_id" in body

            cluster_file = data_dir / "clusters" / f"{body['cluster_id']}.json"
            job_file = data_dir / "jobs" / f"{body['job_id']}.json"
            queue_file = data_dir / "queue" / "pending" / f"{body['job_id']}.json"
            assert cluster_file.exists()
            assert job_file.exists()
            assert queue_file.exists()

            cluster = json.loads(cluster_file.read_text())
            assert cluster["name"] == "twinbox-demo"
            assert cluster["status"] == "requested"
            assert cluster["metadata"]["proxmox_node"] == "pve"
            assert cluster["metadata"]["storage_pool"] == "local-lvm"
            assert cluster["metadata"]["cluster_slug"] == "demo"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_ip_suggestions_uses_management_subnet_and_free_consecutive_block():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text(
            """#!/bin/sh
ip="$1"
case "$ip" in
  192.168.2.20) exit 0 ;;
  *) exit 1 ;;
esac
""",
            encoding="utf-8",
        )
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"vmid": 100},
  {"vmid": 101},
  {"vmid": 102},
  {"vmid": 105}
]
EOF
""",
            encoding="utf-8",
        )
        vm_mock.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            status, body = _get_json(
                f"http://127.0.0.1:{port}/api/ip-suggestions?management_ip=192.168.2.20&node_count=3"
            )
            assert status == 200
            assert body["management_ip"] == "192.168.2.20"
            assert body["subnet"] == "192.168.2.0/24"
            assert body["start_vmid"] == 106
            assert body["vmid_block"] == [106, 107, 108]
            assert body["name_suggestion"] == "twinbox-cluster"
            assert body["vip_ip"] == "192.168.2.50"
            assert body["start_ip"] == "192.168.2.51"
            assert body["start_ip_block"] == [
                "192.168.2.51",
                "192.168.2.52",
                "192.168.2.53",
            ]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_ip_suggestions_uses_cluster_slug_for_name_suggestion():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text("#!/bin/sh\necho '[]'\n", encoding="utf-8")
        vm_mock.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)
        env["TWINBOX_CLUSTER_SLUG"] = "development"

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            status, body = _get_json(
                f"http://127.0.0.1:{port}/api/ip-suggestions?management_ip=192.168.2.20&node_count=2"
            )
            assert status == 200
            assert body["name_suggestion"] == "twinbox-development"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_create_cluster_rejects_occupied_vmid_or_ip_ranges_and_normalizes_name():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text(
            """#!/bin/sh
ip="$1"
case "$ip" in
  192.168.1.50|192.168.1.53) exit 0 ;;
  *) exit 1 ;;
esac
""",
            encoding="utf-8",
        )
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"vmid": 200},
  {"vmid": 201},
  {"vmid": 350}
]
EOF
""",
            encoding="utf-8",
        )
        vm_mock.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            occupied_payload = {
                "name": "development",
                "controlplane_count": 1,
                "worker_count": 2,
                "cpu_cores": 2,
                "memory_mb": 4096,
                "disk_gb": 20,
                "bridge": "vmbr0",
                "start_vmid": 200,
                "vip_ip": "192.168.1.50",
                "start_ip": "192.168.1.51",
            }
            status, body = _post_json(f"{base}/api/clusters", occupied_payload)
            assert status == 400
            assert "VMID range 200-202 is not free" in body["error"]

            ip_payload = {
                **occupied_payload,
                "start_vmid": 202,
            }
            status, body = _post_json(f"{base}/api/clusters", ip_payload)
            assert status == 400
            assert "VIP IP 192.168.1.50 is already in use" in body["error"]

            valid_payload = {
                **occupied_payload,
                "start_vmid": 202,
                "vip_ip": "192.168.1.60",
                "start_ip": "192.168.1.61",
            }
            status, body = _post_json(f"{base}/api/clusters", valid_payload)
            assert status == 202

            cluster_file = data_dir / "clusters" / f"{body['cluster_id']}.json"
            cluster = json.loads(cluster_file.read_text(encoding="utf-8"))
            assert cluster["name"] == "twinbox-development"
            assert cluster["metadata"]["cluster_slug"] == "development"
        finally:
            proc.terminate()
            proc.wait(timeout=5)
