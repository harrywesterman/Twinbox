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


def _put_json(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, method="PUT")
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


def _default_env(td):
    data_dir = Path(td) / "data"
    vm_mock = Path(td) / "mock-vms.sh"
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
    ping_mock = Path(td) / "mock-ping.sh"
    ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    ping_mock.chmod(0o755)
    port = _find_free_port()
    env = os.environ.copy()
    env["MANAGER_DATA_DIR"] = str(data_dir)
    env["MANAGER_API_PORT"] = str(port)
    env["MANAGER_API_PING_BIN"] = str(ping_mock)
    env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)
    return data_dir, port, env


def _spawn_server(data_dir, port, env):
    return subprocess.Popen(
        ["node", "manager-api/src/server.js"],
        cwd=Path(__file__).resolve().parents[2],
        env={**env, "MANAGER_DATA_DIR": str(data_dir), "MANAGER_API_PORT": str(port)},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def test_get_wizard_state_returns_normalized_defaults():
    with tempfile.TemporaryDirectory() as td:
        data_dir, port, env = _default_env(td)
        proc = _spawn_server(data_dir, port, env)
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            status, body = _get_json(f"http://127.0.0.1:{port}/api/wizard/state")
            assert status == 200
            assert body["selectedStepId"] == ""
            assert body["wizardPhase"] == "questions"
            assert body["answers"] == {}
            assert body["clusterId"] == ""
            assert body["clusterCreatedAt"] == ""
            assert body["clusterInstanceId"] == ""
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_put_wizard_state_normalizes_and_persists():
    with tempfile.TemporaryDirectory() as td:
        data_dir, port, env = _default_env(td)
        proc = _spawn_server(data_dir, port, env)
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            payload = {
                "selectedStepId": "configure-dns",
                "wizardPhase": "install",
                "answers": {"configure-dns": {"dns_domain": "example.com"}},
                "clusterId": "demo",
                "clusterCreatedAt": "2025-01-01T00:00:00.000Z",
                "clusterInstanceId": "abc-123",
            }
            status, body = _put_json(f"http://127.0.0.1:{port}/api/wizard/state", payload)
            assert status == 200
            assert body["selectedStepId"] == "configure-dns"
            assert body["wizardPhase"] == "install"

            status, body = _get_json(f"http://127.0.0.1:{port}/api/wizard/state")
            assert status == 200
            assert body["selectedStepId"] == "configure-dns"
            assert body["clusterId"] == "demo"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_put_wizard_state_normalizes_invalid_fields():
    with tempfile.TemporaryDirectory() as td:
        data_dir, port, env = _default_env(td)
        proc = _spawn_server(data_dir, port, env)
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            payload = {
                "selectedStepId": 42,
                "wizardPhase": "invalid_phase",
                "answers": [1, 2, 3],
                "clusterId": None,
            }
            status, _ = _put_json(f"http://127.0.0.1:{port}/api/wizard/state", payload)
            assert status == 200

            status, body = _get_json(f"http://127.0.0.1:{port}/api/wizard/state")
            assert status == 200
            assert body["selectedStepId"] == ""
            assert body["wizardPhase"] == "questions"
            assert body["answers"] == {}
            assert body["clusterId"] == ""
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_startup_handles_wizard_state_json_as_directory():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        wizard_state_dir = data_dir / "wizard-state.json"
        wizard_state_dir.mkdir(parents=True)

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = "/bin/true"
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = "/bin/true"

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
            status, body = _get_json(f"http://127.0.0.1:{port}/api/wizard/state")
            assert status == 200
            assert body["selectedStepId"] == ""

            status, body = _put_json(
                f"http://127.0.0.1:{port}/api/wizard/state",
                {"selectedStepId": "test-step"},
            )
            assert status == 200

            status, body = _get_json(f"http://127.0.0.1:{port}/api/wizard/state")
            assert status == 200
            assert body["selectedStepId"] == "test-step"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_get_wizard_state_with_malformed_json_returns_500():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        data_dir.mkdir(parents=True)
        wizard_state_file = data_dir / "wizard-state.json"
        wizard_state_file.write_text("NOT VALID JSON", encoding="utf-8")

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = "/bin/true"
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = "/bin/true"

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
            status, body = _get_json(f"http://127.0.0.1:{port}/api/wizard/state")
            assert status == 500
            assert "error" in body
        finally:
            proc.terminate()
            proc.wait(timeout=5)
