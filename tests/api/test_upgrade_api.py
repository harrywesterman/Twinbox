import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import error, request

REPO_ROOT = Path(__file__).resolve().parents[2]


def _find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _request_json(url, method="GET", payload=None):
    data = json.dumps(payload or {}).encode("utf-8") if method != "GET" else None
    req = request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=3) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def _wait_for_health(base_url):
    for _ in range(50):
        try:
            if _request_json(f"{base_url}/api/health")[0] == 200:
                return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("manager-api did not become healthy")


def test_upgrade_endpoints_queue_jobs_and_lock_other_cluster_mutations():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        clusters_dir = data_dir / "clusters"
        clusters_dir.mkdir(parents=True)
        cluster = {
            "id": "cluster-test",
            "cluster_instance_id": "instance-test",
            "metadata": {
                "proxmox_node": "pve",
                "storage_pool": "local-lvm",
                "file_datastore": "local",
            },
        }
        (clusters_dir / "cluster-test.json").write_text(json.dumps(cluster), encoding="utf-8")

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
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
            status, initial = _request_json(f"{base}/api/clusters/cluster-test/upgrades")
            assert status == 200
            assert initial["status"] == "idle"

            status, refresh = _request_json(
                f"{base}/api/clusters/cluster-test/upgrades/refresh", method="POST"
            )
            assert status == 202
            assert refresh["state"]["status"] == "inspecting"

            state_file = data_dir / "upgrade-state" / "cluster-test.json"
            state = json.loads(state_file.read_text(encoding="utf-8"))
            state.update(
                {"status": "ready", "phase": "idle", "inspected_at": "2026-06-02T10:00:00Z"}
            )
            state_file.write_text(json.dumps(state), encoding="utf-8")

            status, talos = _request_json(
                f"{base}/api/clusters/cluster-test/upgrades/talos", method="POST"
            )
            assert status == 202
            assert talos["state"]["phase"] == "talos"
            assert talos["state"]["status"] == "pending"

            status, blocked = _request_json(
                f"{base}/api/clusters/cluster-test/observability",
                method="PUT",
                payload={"profile": "minimal"},
            )
            assert status == 409
            assert "cluster maintenance is active" in blocked["error"]

            status, paused = _request_json(
                f"{base}/api/clusters/cluster-test/upgrades/pause", method="POST"
            )
            assert status == 200
            assert paused["pause_requested"] is True
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_upgrade_script_keeps_safety_contracts():
    text = (REPO_ROOT / "scripts" / "manager" / "upgrade-cluster.sh").read_text(encoding="utf-8")
    helper_text = (REPO_ROOT / "scripts" / "get-talos-image-factory.sh").read_text(encoding="utf-8")
    assert "talos etcd snapshot" in text
    assert "--installer-only" in text
    assert "--output extensions" in text
    assert "siderolabs/qemu-guest-agent" in helper_text
    assert "siderolabs/iscsi-tools" in helper_text
    assert "siderolabs/util-linux-tools" in helper_text
    assert text.index("$(jq -r '.[]' <<<\"$controlplanes_json\")") < text.index(
        "$(jq -r '.[]' <<<\"$workers_json\")"
    )
    assert 'upgrade-k8s --to "$normalized" --dry-run' in text
    assert text.index('upgrade-k8s --to "$normalized" --dry-run') < text.index(
        'upgrade-k8s --to "$normalized" --nodes'
    )


def test_upgrade_script_inspects_server_versions_and_builds_sequential_paths():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        bin_dir = root / "bin"
        cluster_dir = data_dir / "clusters"
        cluster_dir.mkdir(parents=True)
        bin_dir.mkdir()
        (cluster_dir / "cluster-test.json").write_text(
            json.dumps(
                {
                    "id": "cluster-test",
                    "controlplane_ips": ["10.0.0.11"],
                    "worker_ips": ["10.0.0.21"],
                }
            ),
            encoding="utf-8",
        )
        talosconfig = root / "talosconfig"
        kubeconfig = root / "kubeconfig"
        talosconfig.write_text("context: test\n", encoding="utf-8")
        kubeconfig.write_text("apiVersion: v1\n", encoding="utf-8")

        _write_executable(
            bin_dir / "talosctl",
            """#!/bin/bash
case "$1" in
  version) printf 'Client:\\n  Tag: v1.13.0\\nServer:\\n  Tag: v1.12.4\\n' ;;
  get) printf '{"spec":{"metadata":{"name":"qemu-guest-agent"}}}\\n{"spec":{"metadata":{"name":"iscsi-tools"}}}\\n{"spec":{"metadata":{"name":"util-linux-tools"}}}\\n{"spec":{"metadata":{"name":"schematic"}}}\\n{"spec":{"metadata":{"name":"unexpected-extension"}}}\\n' ;;
  health)
    [[ "$*" == *"--nodes 10.0.0.11"* ]]
    [[ "$*" == *"--control-plane-nodes 10.0.0.11"* ]]
    [[ "$*" == *"--worker-nodes 10.0.0.21"* ]]
    ;;
  *) exit 0 ;;
esac
""",
        )
        _write_executable(
            bin_dir / "kubectl",
            """#!/bin/bash
if [[ "$1" == "version" ]]; then
  printf '{"serverVersion":{"gitVersion":"v1.35.4"}}'
elif [[ "$1" == "get" && "$2" == "namespace" ]]; then
  exit 1
fi
""",
        )
        _write_executable(
            bin_dir / "curl",
            """#!/bin/bash
url="${*: -1}"
case "$url" in
  *api.github.com*) printf '[{"tag_name":"v1.13.3","draft":false,"prerelease":false},{"tag_name":"v1.12.4","draft":false,"prerelease":false}]' ;;
  *stable-1.36.txt) printf 'v1.36.1' ;;
  *stable.txt) printf 'v1.36.1' ;;
  *) exit 1 ;;
esac
""",
        )
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["TWINBOX_TALOSCONFIG_FILE"] = str(talosconfig)
        env["TWINBOX_KUBECONFIG_FILE"] = str(kubeconfig)
        proc = subprocess.run(
            [
                "bash",
                "scripts/manager/upgrade-cluster.sh",
                "--phase",
                "inspect",
                "--cluster-id",
                "cluster-test",
                "--data-dir",
                str(data_dir),
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        state = json.loads((data_dir / "upgrade-state" / "cluster-test.json").read_text())
        assert state["inventory"]["nodes"][0]["version"] == "v1.12.4"
        assert state["inventory"]["nodes"][0]["extensions"] == [
            "siderolabs/iscsi-tools",
            "siderolabs/qemu-guest-agent",
            "siderolabs/unexpected-extension",
            "siderolabs/util-linux-tools",
        ]
        assert state["paths"]["talos"] == ["v1.13.3"]
        assert state["paths"]["kubernetes"] == ["v1.36.1"]


def _write_executable(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)
