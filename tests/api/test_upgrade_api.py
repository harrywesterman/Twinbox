import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import error, request

import pytest

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
            assert initial["longhorn_maintenance"] == {
                "active": False,
                "original_policy": None,
            }
            assert initial["topology"] == {
                "controlplane_count": 0,
                "mode": None,
                "warning": None,
            }
            assert initial["current_node"] is None

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
    portal_text = (REPO_ROOT / "portal" / "src" / "App.jsx").read_text(encoding="utf-8")
    assert "talos etcd snapshot" in text
    assert "--installer-only" in text
    assert "--output extensions" in text
    assert "siderolabs/qemu-guest-agent" in helper_text
    assert "siderolabs/iscsi-tools" in helper_text
    assert "siderolabs/util-linux-tools" in helper_text
    talos_upgrade_text = text[text.index("talos_upgrade() {") :]
    assert talos_upgrade_text.index("$(jq -r '.[]' <<<\"$controlplanes_json\")") < (
        talos_upgrade_text.index("enable_longhorn_worker_maintenance")
    )
    workers_upgrade_text = talos_upgrade_text[
        talos_upgrade_text.index("$(jq -r '.[]' <<<\"$workers_json\")") :
    ]
    assert workers_upgrade_text.index(
        "enable_longhorn_worker_maintenance"
    ) < workers_upgrade_text.index('talos upgrade --nodes "$node"')
    assert "--drain=false --wait" in workers_upgrade_text
    assert "verify_longhorn_worker_preflight" in workers_upgrade_text
    assert "resolve_endpoint" in text
    assert "disruptive-maintenance" in text
    assert 'upgrade-k8s --to "$normalized" --dry-run' in text
    assert text.index('upgrade-k8s --to "$normalized" --dry-run') < text.index(
        'upgrade-k8s --to "$normalized" --nodes'
    )
    assert 'set_longhorn_policy "always-allow"' in text
    assert "restore_longhorn_worker_maintenance" in text
    assert "Tijdelijke Longhorn-maintenance actief" in portal_text
    assert "een worker die niet terugkomt kan dataverlies veroorzaken" in portal_text


@pytest.mark.parametrize(
    ("controlplane_count", "expected_mode", "expects_warning"),
    [
        (1, "disruptive-maintenance", True),
        (2, "disruptive-maintenance", True),
        (3, "rolling", False),
        (4, "rolling", True),
    ],
)
def test_upgrade_script_inspects_server_versions_and_builds_sequential_paths(
    controlplane_count, expected_mode, expects_warning
):
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        bin_dir = root / "bin"
        cluster_dir = data_dir / "clusters"
        cluster_dir.mkdir(parents=True)
        bin_dir.mkdir()
        controlplane_ips = [f"10.0.0.{11 + index}" for index in range(controlplane_count)]
        (cluster_dir / "cluster-test.json").write_text(
            json.dumps(
                {
                    "id": "cluster-test",
                    "controlplane_ips": controlplane_ips,
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
  version)
    if [[ "${FAIL_FIRST_ENDPOINT:-}" == "true" && "$*" == *"--endpoints 10.0.0.11"* ]]; then
      exit 1
    fi
    printf 'Client:\\n  Tag: v1.13.0\\nServer:\\n  NODE: 10.0.0.11\\n  Tag: v1.12.4\\n'
    ;;
  get) printf '{"spec":{"metadata":{"name":"qemu-guest-agent"}}}\\n{"spec":{"metadata":{"name":"iscsi-tools"}}}\\n{"spec":{"metadata":{"name":"util-linux-tools"}}}\\n{"spec":{"metadata":{"name":"schematic"}}}\\n{"spec":{"metadata":{"name":"unexpected-extension"}}}\\n' ;;
  health) ;;
  etcd) ;;
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
        env["FAIL_FIRST_ENDPOINT"] = "true" if controlplane_count == 2 else ""
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
        assert state["topology"]["controlplane_count"] == controlplane_count
        assert state["topology"]["mode"] == expected_mode
        if expects_warning:
            assert state["topology"]["warning"]
        else:
            assert state["topology"]["warning"] is None


def _write_executable(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


@pytest.mark.parametrize(
    ("mode", "expected_status"),
    [
        ("success", "talos_completed"),
        ("failure", "pending"),
        ("health-failure", "pending"),
        ("attachment-failure", "pending"),
        ("replica-failure", "pending"),
        ("pause", "paused"),
    ],
)
def test_talos_worker_upgrade_temporarily_uses_and_restores_longhorn_always_allow(
    mode, expected_status
):
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        bin_dir = root / "bin"
        cluster_dir = data_dir / "clusters"
        state_dir = data_dir / "upgrade-state"
        cluster_dir.mkdir(parents=True)
        state_dir.mkdir()
        bin_dir.mkdir()
        log_file = root / "calls.log"
        policy_file = root / "longhorn-policy.txt"
        cordon_file = root / "worker-cordoned.txt"
        policy_file.write_text("allow-if-replica-is-stopped", encoding="utf-8")
        cordon_file.write_text("true" if mode != "success" else "false", encoding="utf-8")
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
        checkpoints = ["v1.13.3:10.0.0.11"] if mode != "success" else []
        (state_dir / "cluster-test.json").write_text(
            json.dumps(
                {
                    "cluster_id": "cluster-test",
                    "phase": "talos",
                    "status": "pending",
                    "pause_requested": mode == "pause",
                    "inventory": {"nodes": [{"version": "v1.13.0"}]},
                    "paths": {"talos": ["v1.13.3"], "kubernetes": []},
                    "checkpoints": {"talos": checkpoints, "kubernetes": []},
                    "longhorn_maintenance": {"active": False, "original_policy": None},
                }
            ),
            encoding="utf-8",
        )
        talosconfig = root / "talosconfig"
        kubeconfig = root / "kubeconfig"
        talosconfig.write_text("context: test\n", encoding="utf-8")
        kubeconfig.write_text("apiVersion: v1\n", encoding="utf-8")

        fake_talosctl = bin_dir / "talosctl"
        _write_executable(
            fake_talosctl,
            """#!/bin/bash
set -euo pipefail
printf 'talosctl %s\\n' "$*" >> "$TEST_LOG"
case "$1" in
  health) ;;
  etcd)
    case "$2" in
      snapshot) mkdir -p "$(dirname "$3")"; : > "$3" ;;
      status) ;;
      alarm) ;;
    esac
    ;;
  get) printf '{"spec":{"metadata":{"name":"qemu-guest-agent"}}}\\n{"spec":{"metadata":{"name":"iscsi-tools"}}}\\n{"spec":{"metadata":{"name":"util-linux-tools"}}}\\n' ;;
  upgrade)
    if [[ "${FAIL_WORKER:-}" == "true" && "$*" == *"--nodes 10.0.0.21"* ]]; then
      exit 1
    fi
    if [[ "$*" == *"--nodes 10.0.0.21"* ]]; then
      : > "$TEST_WORKER_UPGRADED"
    fi
    ;;
esac
""",
        )
        _write_executable(
            bin_dir / "kubectl",
            """#!/bin/bash
set -euo pipefail
printf 'kubectl %s\\n' "$*" >> "$TEST_LOG"
if [[ "$*" == "get namespace longhorn-system" ]]; then
  exit 0
fi
if [[ "$*" == "get nodes -o json" ]]; then
  printf '{"items":[{"metadata":{"name":"talos-worker"},"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.21"}]}}]}'
  exit 0
fi
if [[ "$*" == "get node talos-worker -o json" ]]; then
  printf '{"spec":{"unschedulable":%s},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' "$(cat "$TEST_CORDON")"
  exit 0
fi
if [[ "$*" == "uncordon talos-worker" ]]; then
  printf 'false' > "$TEST_CORDON"
  exit 0
fi
if [[ "$*" == *"get settings.longhorn.io node-drain-policy -o json"* ]]; then
  printf '{"value":"%s"}' "$(cat "$TEST_POLICY")"
  exit 0
fi
if [[ "$*" == *"patch settings.longhorn.io node-drain-policy"* ]]; then
  if [[ "$*" == *"always-allow"* ]]; then
    printf 'always-allow' > "$TEST_POLICY"
  else
    printf 'allow-if-replica-is-stopped' > "$TEST_POLICY"
  fi
  exit 0
fi
if [[ "$*" == *"get volumes.longhorn.io -o json"* ]]; then
  if [[ "${FAIL_HEALTH:-}" == "true" && -f "$TEST_WORKER_UPGRADED" ]]; then
    printf '{"items":[{"status":{"robustness":"degraded"}}]}'
    exit 0
  fi
  printf '{"items":[]}'
  exit 0
fi
if [[ "$*" == *"get volumeattachments.longhorn.io -o json"* ]]; then
  if [[ "${FAIL_ATTACHMENT:-}" == "true" ]]; then
    printf '{"items":[{"metadata":{"name":"manual-volume"},"spec":{"attachmentTickets":{"manual":{"nodeID":"talos-worker","type":"longhorn-ui"}}}}]}'
    exit 0
  fi
  printf '{"items":[]}'
  exit 0
fi
if [[ "$*" == *"get replicas.longhorn.io -o json"* ]]; then
  if [[ "${FAIL_REPLICA:-}" == "true" ]]; then
    printf '{"items":[{"spec":{"volumeName":"failed-replica","nodeID":"talos-worker","active":true,"failedAt":"2026-06-02T00:00:00Z"},"status":{"currentState":"stopped","started":false}}]}'
    exit 0
  fi
  printf '{"items":[{"spec":{"volumeName":"single-replica","nodeID":"talos-worker","active":true,"failedAt":""},"status":{"currentState":"running","started":true}}]}'
  exit 0
fi
if [[ "$1" == "wait" ]]; then
  exit 0
fi
exit 1
""",
        )
        _write_executable(
            bin_dir / "curl",
            f"""#!/bin/bash
set -euo pipefail
output=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-o" ]]; then output="$argument"; fi
  previous="$argument"
done
url="${{@: -1}}"
if [[ -n "$output" ]]; then
  cp "{fake_talosctl}" "$output"
elif [[ "$url" == *"/sha256sum.txt" ]]; then
  printf 'checksum  talosctl-linux-amd64\\n'
elif [[ "$url" == *"/schematics" ]]; then
  cat >/dev/null
  printf '{{"id":"schematic-test"}}'
else
  exit 1
fi
""",
        )
        _write_executable(
            bin_dir / "sha256sum",
            """#!/bin/bash
printf 'checksum  %s\\n' "$1"
""",
        )
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "TWINBOX_TALOSCONFIG_FILE": str(talosconfig),
                "TWINBOX_KUBECONFIG_FILE": str(kubeconfig),
                "TWINBOX_TALOS_BACKUP_ROOT": str(root / "backups"),
                "TEST_LOG": str(log_file),
                "TEST_POLICY": str(policy_file),
                "TEST_CORDON": str(cordon_file),
                "TEST_WORKER_UPGRADED": str(root / "worker-upgraded.txt"),
                "FAIL_WORKER": "true" if mode == "failure" else "",
                "FAIL_HEALTH": "true" if mode == "health-failure" else "",
                "FAIL_ATTACHMENT": "true" if mode == "attachment-failure" else "",
                "FAIL_REPLICA": "true" if mode == "replica-failure" else "",
                "TWINBOX_LONGHORN_HEALTH_TIMEOUT_SECONDS": "0",
            }
        )
        proc = subprocess.run(
            [
                "bash",
                "scripts/manager/upgrade-cluster.sh",
                "--phase",
                "talos",
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
        if mode in {"failure", "health-failure", "attachment-failure", "replica-failure"}:
            assert proc.returncode != 0
        else:
            assert proc.returncode == 0, proc.stderr
        state = json.loads((state_dir / "cluster-test.json").read_text(encoding="utf-8"))
        calls = log_file.read_text(encoding="utf-8")
        assert state["status"] == expected_status
        assert state["longhorn_maintenance"] == {"active": False, "original_policy": None}
        assert policy_file.read_text(encoding="utf-8") == "allow-if-replica-is-stopped"
        expected_policy_patches = 0 if mode in {"attachment-failure", "replica-failure"} else 2
        assert (
            calls.count("patch settings.longhorn.io node-drain-policy") == expected_policy_patches
        )
        if mode == "success":
            assert calls.index("talosctl upgrade --nodes 10.0.0.11") < calls.index(
                "patch settings.longhorn.io node-drain-policy"
            )
            assert "talosctl upgrade --nodes 10.0.0.21" in calls
            assert "--drain=false --wait" in calls
        elif mode not in {"attachment-failure", "replica-failure"}:
            assert "talosctl upgrade --nodes 10.0.0.11" not in calls
            assert "kubectl uncordon talos-worker" in calls
        else:
            assert "talosctl upgrade --nodes 10.0.0.21" not in calls
