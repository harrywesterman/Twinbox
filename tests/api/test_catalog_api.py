import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import error, request


REPO_ROOT = Path(__file__).resolve().parents[2]


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


def _get_json(url):
    req = request.Request(url, method="GET")
    try:
        with request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, json.loads(body)


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


def _start_api(data_dir: Path, port: int):
    ping_mock = data_dir.parent / "mock-ping.sh"
    vm_mock = data_dir.parent / "mock-vms.sh"
    ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    ping_mock.chmod(0o755)
    vm_mock.write_text("#!/bin/sh\necho '[]'\n", encoding="utf-8")
    vm_mock.chmod(0o755)
    env = os.environ.copy()
    env["MANAGER_DATA_DIR"] = str(data_dir)
    env["MANAGER_API_PORT"] = str(port)
    env["WORKSPACE_ROOT"] = str(REPO_ROOT)
    env["MANAGER_API_PING_BIN"] = str(ping_mock)
    env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)
    return subprocess.Popen(
        ["node", "manager-api/src/server.js"],
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def test_catalog_endpoint_returns_manifest_categories_and_steps():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200
            assert body["errors"] == []
            assert [category["id"] for category in body["categories"]] == [
                "management-vm",
                "talos-cluster",
            ]

            management = body["categories"][0]
            assert [step["id"] for step in management["steps"]] == [
                "configure-automatic-updates",
                "install-k9s",
            ]
            assert management["steps"][0]["type"] == "config"
            assert management["steps"][0]["journey_stage"] == "manage"
            assert management["steps"][0]["status"] == "ready"
            assert management["steps"][1]["type"] == "action"
            assert management["steps"][1]["journey_stage"] == "manage"
            assert management["steps"][1]["status"] == "ready"

            talos = body["categories"][1]
            assert [step["id"] for step in talos["steps"]] == [
                "provision-nodes",
                "install-secret-sync",
            ]
            assert talos["steps"][0]["journey_stage"] == "setup"
            assert talos["steps"][0]["status"] == "ready"
            assert talos["steps"][1]["status"] == "locked"
            assert talos["steps"][1]["secrets"]["files"]["KUBECONFIG_FILE"]["item"] == "kubeconfig"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_rejects_invalid_manifest_inputs():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/provision-nodes/execute",
                {"inputs": {"controlplane_count": 0}},
            )
            assert status == 400
            assert "controlplane_count" in body["error"]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_persists_state_and_enqueues_run_step_job():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/provision-nodes/execute",
                {
                    "inputs": {
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
                },
            )
            assert status == 202
            assert body["job_type"] == "run_step"
            assert body["step_id"] == "provision-nodes"

            step_state = json.loads(
                (data_dir / "step-state" / "provision-nodes.json").read_text()
            )
            assert body["cluster_id"] == step_state["cluster_id"]
            assert step_state["step_id"] == "provision-nodes"
            assert step_state["inputs"]["name"] == "demo"
            assert step_state["status"] == "pending"

            job = json.loads((data_dir / "jobs" / f"{body['job_id']}.json").read_text())
            assert job["type"] == "run_step"
            assert job["payload"]["step_id"] == "provision-nodes"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_endpoint_isolates_invalid_manifest_entries():
    with tempfile.TemporaryDirectory() as td:
        temp_root = Path(td)
        data_dir = temp_root / "data"
        workspace_root = temp_root / "workspace"
        shutil.copytree(REPO_ROOT / "categories", workspace_root / "categories")

        broken_category_dir = workspace_root / "categories" / "broken-category"
        broken_category_dir.mkdir(parents=True)
        (broken_category_dir / "category.yaml").write_text(
            "id: broken-category\n"
            "title: Broken Category\n"
            "order: 99\n",
            encoding="utf-8",
        )

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["WORKSPACE_ROOT"] = str(workspace_root)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200
            assert [category["id"] for category in body["categories"]] == [
                "management-vm",
                "talos-cluster",
            ]
            assert any("broken-category" in error for error in body["errors"])
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_keeps_latest_cluster_step_state_for_follow_up_steps():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)
        (data_dir / "jobs").mkdir(parents=True, exist_ok=True)

        cluster_id = "cluster_old"
        (data_dir / "clusters" / f"{cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": cluster_id,
                    "name": "twinbox-old",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:10:00Z",
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "provision-nodes.json").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "old"},
                    "outputs": {"cluster_id": cluster_id},
                    "cluster_id": cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200

            talos = body["categories"][1]
            assert talos["steps"][0]["id"] == "provision-nodes"
            assert talos["steps"][0]["status"] == "done"
            assert talos["steps"][0]["state"]["cluster_id"] == cluster_id
            assert talos["steps"][1]["id"] == "install-secret-sync"
            assert talos["steps"][1]["status"] == "ready"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_cluster_id_query_scopes_follow_up_state_to_requested_cluster():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)

        older_cluster_id = "cluster_a"
        newer_cluster_id = "cluster_b"
        (data_dir / "clusters" / f"{older_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": older_cluster_id,
                    "name": "twinbox-a",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:05:00Z",
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "clusters" / f"{newer_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": newer_cluster_id,
                    "name": "twinbox-b",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T11:00:00Z",
                    "updated_at": "2026-03-20T11:05:00Z",
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "provision-nodes.json").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "older"},
                    "outputs": {"cluster_id": older_cluster_id},
                    "cluster_id": older_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:06:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog?cluster_id={older_cluster_id}")
            assert status == 200

            talos = body["categories"][1]
            assert talos["steps"][0]["id"] == "provision-nodes"
            assert talos["steps"][0]["status"] == "done"
            assert talos["steps"][0]["state"]["cluster_id"] == older_cluster_id
            assert talos["steps"][1]["id"] == "install-secret-sync"
            assert talos["steps"][1]["status"] == "ready"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_synthesizes_provision_state_for_bootstrapped_cluster_without_step_state():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        cluster_id = "compat-cluster"
        (data_dir / "clusters" / f"{cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": cluster_id,
                    "name": "compat-cluster",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:05:00Z",
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog?cluster_id={cluster_id}")
            assert status == 200

            talos = body["categories"][1]
            assert talos["steps"][0]["id"] == "provision-nodes"
            assert talos["steps"][0]["status"] == "done"
            assert talos["steps"][0]["state"]["cluster_id"] == cluster_id
            assert talos["steps"][0]["state"]["outputs"]["cluster_status"] == "bootstrapped"
            assert talos["steps"][1]["id"] == "install-secret-sync"
            assert talos["steps"][1]["status"] == "ready"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_follow_up_cluster_step_requires_explicit_cluster_context():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)
        (data_dir / "jobs").mkdir(parents=True, exist_ok=True)

        cluster_id = "cluster_followup"
        (data_dir / "clusters" / f"{cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": cluster_id,
                    "name": "twinbox-followup",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:10:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {"scope": "cluster", "item": "talos-secrets", "cluster_id": cluster_id},
                            "talosconfig": {"scope": "cluster", "item": "talosconfig", "cluster_id": cluster_id},
                            "kubeconfig": {"scope": "cluster", "item": "kubeconfig", "cluster_id": cluster_id},
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "provision-nodes.json").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "followup"},
                    "outputs": {"cluster_id": cluster_id},
                    "cluster_id": cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/install-secret-sync/execute",
                {"inputs": {}},
            )
            assert status == 400
            assert body["error"] == "cluster_id is required for follow-up cluster steps"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_follow_up_cluster_step_uses_requested_cluster_context_and_secret_bundle():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)
        (data_dir / "jobs").mkdir(parents=True, exist_ok=True)

        selected_cluster_id = "cluster_followup"
        newer_cluster_id = "cluster_newer"
        (data_dir / "clusters" / f"{selected_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": selected_cluster_id,
                    "name": "twinbox-followup",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:10:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {"scope": "cluster", "item": "talos-secrets", "cluster_id": selected_cluster_id},
                            "talosconfig": {"scope": "cluster", "item": "talosconfig", "cluster_id": selected_cluster_id},
                            "kubeconfig": {"scope": "cluster", "item": "kubeconfig", "cluster_id": selected_cluster_id},
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "clusters" / f"{newer_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": newer_cluster_id,
                    "name": "twinbox-newer",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T11:00:00Z",
                    "updated_at": "2026-03-20T11:05:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {"scope": "cluster", "item": "talos-secrets", "cluster_id": newer_cluster_id},
                            "talosconfig": {"scope": "cluster", "item": "talosconfig", "cluster_id": newer_cluster_id},
                            "kubeconfig": {"scope": "cluster", "item": "kubeconfig", "cluster_id": newer_cluster_id},
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "provision-nodes.json").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "followup"},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/install-secret-sync/execute",
                {"cluster_id": selected_cluster_id, "inputs": {}},
            )
            assert status == 202

            job = json.loads((data_dir / "jobs" / f"{body['job_id']}.json").read_text())
            assert job["type"] == "run_step"
            assert job["cluster_id"] == selected_cluster_id
            assert job["payload"]["context"]["cluster"]["id"] == selected_cluster_id
            assert job["payload"]["secret_bundle"]["files"]["KUBECONFIG_FILE"]["item"] == "kubeconfig"
            assert job["payload"]["secret_bundle"]["files"]["KUBECONFIG_FILE"]["attachment"] == "kubeconfig"
        finally:
            proc.terminate()
            proc.wait(timeout=5)
