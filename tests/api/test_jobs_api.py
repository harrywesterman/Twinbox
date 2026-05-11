import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import error, request


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
    try:
        with request.urlopen(url, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, json.loads(body)


def test_job_status_and_logs_endpoints():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text(
            """#!/bin/sh
exit 1
""",
            encoding="utf-8",
        )
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
                "name": "development",
                "controlplane_count": 1,
                "worker_count": 1,
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
                "dns_domain": "lab.local",
            }
            status, created = _post_json(f"{base}/api/clusters", payload)
            assert status == 202
            job_id = created["job_id"]
            cluster_id = created["cluster_id"]

            status, cluster = _get_json(f"{base}/api/clusters/{cluster_id}")
            assert status == 200
            assert cluster["name"] == "twinbox-development"

            status, job = _get_json(f"{base}/api/jobs/{job_id}")
            assert status == 200
            assert job["status"] == "pending"
            assert job["type"] == "apply_cluster"

            status, logs = _get_json(f"{base}/api/jobs/{job_id}/logs")
            assert status == 200
            assert isinstance(logs["lines"], list)
            assert any("queued apply_cluster" in entry["line"] for entry in logs["lines"])

            status, boot = _post_json(f"{base}/api/clusters/{cluster_id}/bootstrap", {})
            assert status == 202
            assert "job_id" in boot

            status, missing = _get_json(f"{base}/api/jobs/job_missing")
            assert status == 404
            assert missing["error"] == "job not found"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_job_cancel_endpoint_marks_pending_job_canceled():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        pending_dir = data_dir / "queue" / "pending"
        jobs_dir = data_dir / "jobs"
        logs_dir = data_dir / "logs"
        pending_dir.mkdir(parents=True, exist_ok=True)
        jobs_dir.mkdir(parents=True, exist_ok=True)
        logs_dir.mkdir(parents=True, exist_ok=True)

        job = {
            "id": "job_cancel_me",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "choose-ingress-route",
                "step_type": "config",
                "inputs": {},
                "runner": {"kind": "script", "script": "scripts/mock.sh"},
                "context": {},
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (jobs_dir / "job_cancel_me.json").write_text(json.dumps(job))
        (pending_dir / "job_cancel_me.json").write_text(
            json.dumps(
                {
                    "id": "job_cancel_me",
                    "type": "run_step",
                    "cluster_id": "cluster_test",
                    "payload": job["payload"],
                    "queued_at": "2026-01-01T00:00:00Z",
                }
            )
        )

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
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, canceled = _post_json(f"{base}/api/jobs/job_cancel_me/cancel", {})
            assert status == 200
            assert canceled["status"] == "canceled"

            status, job_data = _get_json(f"{base}/api/jobs/job_cancel_me")
            assert status == 200
            assert job_data["status"] == "canceled"
            assert job_data["step"] == "canceled"
            assert not (pending_dir / "job_cancel_me.json").exists()
        finally:
            proc.terminate()
            proc.wait(timeout=5)
