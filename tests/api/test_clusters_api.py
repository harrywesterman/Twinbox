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
        vm_mock = Path(td) / "mock-vms.sh"
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online", "vmid": 200},
  {"node": "pve-b", "status": "online", "vmid": 201},
  {"node": "pve-c", "status": "online", "vmid": 350}
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
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online"},
  {"node": "pve-b", "status": "online"}
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
                "node_prefix_length": 24,
                "gateway_ip": "192.168.1.1",
                "dns_servers": "1.1.1.1, 1.0.0.1",
                "dns_domain": "lab.local",
            }
            status, body = _post_json(f"http://127.0.0.1:{port}/api/clusters", payload)
            assert status == 202
            assert body["cluster_id"] == "demo"
            assert "job_id" in body

            cluster_file = data_dir / "clusters" / f"{body['cluster_id']}.json"
            job_file = data_dir / "jobs" / f"{body['job_id']}.json"
            queue_file = data_dir / "queue" / "pending" / f"{body['job_id']}.json"
            assert cluster_file.exists()
            assert job_file.exists()
            assert queue_file.exists()

            cluster = json.loads(cluster_file.read_text())
            job = json.loads(job_file.read_text())
            queue_entry = json.loads(queue_file.read_text())
            assert cluster["name"] == "twinbox-demo"
            assert cluster["status"] == "requested"
            assert cluster["metadata"]["proxmox_node"] == "pve"
            assert cluster["metadata"]["storage_pool"] == "local-lvm"
            assert cluster["metadata"]["file_datastore"] == "local"
            assert cluster["metadata"]["cluster_slug"] == "demo"
            assert cluster["metadata"]["talos_image_preset"] == "qemu-guest-agent"
            assert cluster["vm_node_map"] == {
                "cp-1": "pve-a",
                "worker-1": "pve-b",
                "worker-2": "pve-a",
            }
            assert cluster["metadata"]["secret_refs"]["proxmox"]["scope"] == "global"
            assert cluster["metadata"]["secret_refs"]["proxmox"]["item"] == "proxmox"
            assert cluster["spec_version"] == "iac-v1"
            assert cluster["node_prefix_length"] == 24
            assert cluster["gateway_ip"] == "192.168.1.1"
            assert cluster["dns_servers"] == ["1.1.1.1", "1.0.0.1"]
            assert cluster["dns_domain"] == "lab.local"
            assert "talos_config_dir" not in json.dumps(cluster)
            assert "talosconfig_path" not in json.dumps(cluster)
            assert "kubeconfig_path" not in json.dumps(cluster)
            assert "PROXMOX_PASSWORD" not in json.dumps(cluster)
            assert job["payload"]["secret_bundle"]["env"]["TF_VAR_proxmox_password"]["field"] == "password"
            assert job["payload"]["secret_bundle"]["env"]["TF_VAR_proxmox_password"]["item"] == "proxmox"
            assert queue_entry["payload"]["secret_bundle"]["env"]["TF_VAR_proxmox_password"]["field"] == "password"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_create_cluster_rejects_unknown_vm_hosts():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online"},
  {"node": "pve-b", "status": "online"}
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
                "node_prefix_length": 24,
                "gateway_ip": "192.168.1.1",
                "dns_servers": "1.1.1.1, 1.0.0.1",
                "dns_domain": "lab.local",
                "vm_node_map": {
                    "cp-1": "pve-a",
                    "worker-1": "pve-b",
                    "worker-2": "missing-host",
                },
            }
            status, body = _post_json(f"http://127.0.0.1:{port}/api/clusters", payload)
            assert status == 400
            assert "unknown Proxmox host" in body["error"]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_ip_suggestions_uses_management_subnet_and_free_consecutive_block():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ip_mock = Path(td) / "mock-ip.sh"
        resolv_conf = Path(td) / "resolv.conf"
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
        ip_mock.write_text(
            """#!/bin/sh
if [ "$1" = "-o" ] && [ "$2" = "-f" ] && [ "$3" = "inet" ] && [ "$4" = "addr" ] && [ "$5" = "show" ] && [ "$6" = "scope" ] && [ "$7" = "global" ]; then
  echo "2: eth0    inet 192.168.2.20/24 brd 192.168.2.255 scope global eth0"
  exit 0
fi

if [ "$1" = "route" ]; then
  echo "default via 192.168.2.1 dev eth0"
  exit 0
fi

exit 1
""",
            encoding="utf-8",
        )
        ip_mock.chmod(0o755)
        resolv_conf.write_text(
            "search westermanonline.internal\nnameserver 1.1.1.1\nnameserver 9.9.9.9\n",
            encoding="utf-8",
        )

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)
        env["MANAGER_API_IP_BIN"] = str(ip_mock)
        env["MANAGER_API_RESOLV_CONF"] = str(resolv_conf)

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
            assert body["node_prefix_length"] == 24
            assert body["gateway_ip"] == "192.168.2.1"
            assert body["dns_servers"] == ["1.1.1.1", "9.9.9.9"]
            assert body["dns_domain"] == "westermanonline.internal"
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
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online"},
  {"node": "pve-b", "status": "online"}
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


def test_ip_suggestions_filters_container_dns_and_placeholder_domain():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ip_mock = Path(td) / "mock-ip.sh"
        resolv_conf = Path(td) / "resolv.conf"
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online"},
  {"node": "pve-b", "status": "online"}
]
EOF
""",
            encoding="utf-8",
        )
        vm_mock.chmod(0o755)
        ip_mock.write_text(
            """#!/bin/sh
if [ "$1" = "-o" ] && [ "$2" = "-f" ] && [ "$3" = "inet" ] && [ "$4" = "addr" ] && [ "$5" = "show" ] && [ "$6" = "scope" ] && [ "$7" = "global" ]; then
  echo "2: eth0    inet 192.168.2.51/24 brd 192.168.2.255 scope global eth0"
  exit 0
fi

if [ "$1" = "route" ]; then
  echo "default via 172.18.0.1 dev eth0"
  exit 0
fi

exit 1
""",
            encoding="utf-8",
        )
        ip_mock.chmod(0o755)
        resolv_conf.write_text(
            "search localdomain\nnameserver 127.0.0.11\nnameserver 1.1.1.1\nnameserver 127.0.0.53\n",
            encoding="utf-8",
        )

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)
        env["MANAGER_API_IP_BIN"] = str(ip_mock)
        env["MANAGER_API_RESOLV_CONF"] = str(resolv_conf)

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
                f"http://127.0.0.1:{port}/api/ip-suggestions?management_ip=192.168.2.51&node_count=3"
            )
            assert status == 200
            assert body["gateway_ip"] == "192.168.2.1"
            assert body["dns_servers"] == ["1.1.1.1"]
            assert body["dns_domain"] == ""
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_create_cluster_accepts_empty_dns_domain():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online"},
  {"node": "pve-b", "status": "online"}
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
                "node_prefix_length": 24,
                "gateway_ip": "192.168.1.1",
                "dns_servers": "1.1.1.1, 1.0.0.1",
                "dns_domain": "",
            }
            status, body = _post_json(f"http://127.0.0.1:{port}/api/clusters", payload)
            assert status == 202

            cluster_file = data_dir / "clusters" / f"{body['cluster_id']}.json"
            cluster = json.loads(cluster_file.read_text())
            assert cluster["dns_domain"] == ""
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
  {"node": "pve-a", "status": "online", "vmid": 200},
  {"node": "pve-b", "status": "online", "vmid": 201}
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
                "node_prefix_length": 24,
                "gateway_ip": "192.168.1.1",
                "dns_servers": "1.1.1.1,8.8.8.8",
                "dns_domain": "cluster.internal",
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
            assert body["cluster_id"] == "development"

            cluster_file = data_dir / "clusters" / f"{body['cluster_id']}.json"
            cluster = json.loads(cluster_file.read_text(encoding="utf-8"))
            assert cluster["name"] == "twinbox-development"
            assert cluster["metadata"]["cluster_slug"] == "development"
            assert cluster["dns_servers"] == ["1.1.1.1", "8.8.8.8"]
            assert cluster["dns_domain"] == "cluster.internal"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_create_cluster_rejects_invalid_static_network_inputs():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online"},
  {"node": "pve-b", "status": "online"}
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
            payload = {
                "name": "demo",
                "controlplane_count": 1,
                "worker_count": 1,
                "cpu_cores": 2,
                "memory_mb": 4096,
                "disk_gb": 20,
                "bridge": "vmbr0",
                "start_vmid": 200,
                "vip_ip": "192.168.1.50",
                "start_ip": "192.168.1.51",
                "node_prefix_length": 33,
                "gateway_ip": "192.168.1.1",
                "dns_servers": "1.1.1.1,8.8.8.8",
                "dns_domain": "cluster.internal",
            }

            status, body = _post_json(f"{base}/api/clusters", payload)
            assert status == 400
            assert "node_prefix_length must be an integer between 1 and 32" in body["error"]

            payload["node_prefix_length"] = 24
            payload["dns_servers"] = "1.1.1.1,not-an-ip"
            status, body = _post_json(f"{base}/api/clusters", payload)
            assert status == 400
            assert "dns_servers must contain valid IPv4 addresses" in body["error"]
        finally:
            proc.terminate()
            proc.wait(timeout=5)
