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
            assert cluster["name"] == "demo"
            assert cluster["status"] == "requested"
        finally:
            proc.terminate()
            proc.wait(timeout=5)
