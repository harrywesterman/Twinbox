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


def _write_cluster_file(
    data_dir: Path,
    cluster_id: str,
    *,
    slug: str,
    dns_domain: str,
    selected_ingress_route: str,
    updated_at: str,
):
    cluster_file = data_dir / "clusters" / f"{cluster_id}.json"
    cluster_file.parent.mkdir(parents=True, exist_ok=True)
    cluster_file.write_text(
        json.dumps(
            {
                "id": cluster_id,
                "slug": slug,
                "dns_domain": dns_domain,
                "selected_ingress_route": selected_ingress_route,
                "updated_at": updated_at,
            }
        ),
        encoding="utf-8",
    )


def _cluster_step_state(data_dir: Path, cluster_id: str, step_id: str) -> Path:
    return data_dir / "step-state" / "clusters" / cluster_id / f"{step_id}.json"


def _write_succeeded_step_state(data_dir: Path, cluster_id: str, step_id: str):
    _cluster_step_state(data_dir, cluster_id, step_id).parent.mkdir(parents=True, exist_ok=True)
    _cluster_step_state(data_dir, cluster_id, step_id).write_text(
        json.dumps(
            {
                "status": "succeeded",
                "inputs": {},
                "outputs": {},
                "cluster_id": cluster_id,
                "cluster_instance_id": cluster_id,
                "error": None,
                "updated_at": "2026-04-19T00:00:00Z",
                "last_job_id": None,
            }
        ),
        encoding="utf-8",
    )


def _copy_categories_without_opencloud(destination: Path):
    shutil.copytree(REPO_ROOT / "categories", destination)


def _start_api(data_dir: Path, port: int, categories_dir: Path):
    ping_mock = data_dir.parent / "mock-ping.sh"
    vm_mock = data_dir.parent / "mock-vms.sh"
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
    env = os.environ.copy()
    env["MANAGER_DATA_DIR"] = str(data_dir)
    env["MANAGER_API_PORT"] = str(port)
    env["WORKSPACE_ROOT"] = str(REPO_ROOT)
    env["TWINBOX_CATEGORIES_DIR"] = str(categories_dir)
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


def test_apps_catalog_exposes_jitsi_as_installable():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        categories_dir = root / "categories"
        _copy_categories_without_opencloud(categories_dir)
        _write_cluster_file(
            data_dir,
            "cluster-demo",
            slug="cluster-demo",
            dns_domain="example.com",
            selected_ingress_route="netbird",
            updated_at="2026-04-19T00:00:00Z",
        )
        for step_id in (
            "install-secret-sync",
            "install-authentik-idp",
            "create-users-and-groups",
            "choose-ingress-route",
        ):
            _write_succeeded_step_state(data_dir, "cluster-demo", step_id)

        port = _find_free_port()
        proc = _start_api(data_dir, port, categories_dir)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/apps/catalog?cluster_id=cluster-demo")
            assert status == 200
            assert body["errors"] == []
            apps = body["categories"][0]["steps"]
            jitsi = next(step for step in apps if step["id"] == "install-jitsi")
            assert jitsi["placeholder"] is False
            assert jitsi["installable"] is True
            assert jitsi["app_state"] == "ready"
            assert jitsi["runner"]["script"] == "categories/apps/steps/install-jitsi/run.sh"
        finally:
            proc.terminate()
            proc.wait(timeout=5)
