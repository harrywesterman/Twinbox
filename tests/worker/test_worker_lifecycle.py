import json
import os
import subprocess
import tempfile
import time
from pathlib import Path


def _wait_until(predicate, timeout=10):
    start = time.time()
    while time.time() - start < timeout:
        if predicate():
            return
        time.sleep(0.2)
    raise RuntimeError("condition not met in time")


def _write_fake_tool(path: Path, body: str):
    path.write_text(body)
    path.chmod(0o755)


def _prepare_fake_toolchain(bin_dir: Path):
    _write_fake_tool(
        bin_dir / "talosctl",
        "#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo 'Client: v1.7.4'; exit 0; fi\nexit 0\n",
    )
    _write_fake_tool(
        bin_dir / "kubectl",
        "#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo '{\"clientVersion\":{\"gitVersion\":\"v1.30.0\"}}'; exit 0; fi\nexit 0\n",
    )
    _write_fake_tool(
        bin_dir / "helm",
        "#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo 'v3.15.4+gabcdef'; exit 0; fi\nexit 0\n",
    )


def _write_pinned_defaults(workspace: Path, talos_version: str = "v1.7.4"):
    config_dir = workspace / "config"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "pinned-defaults.sh").write_text(
        f"PINNED_TALOS_VERSION={talos_version}\nPINNED_PROXMOX_ISO_STORAGE=local\n",
    )


def test_worker_processes_pending_job_to_completed():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"
        pending = data / "queue" / "pending"
        jobs = data / "jobs"
        logs = data / "logs"
        clusters = data / "clusters"
        script_dir = workspace / "scripts" / "manager"

        for d in [pending, jobs, logs, clusters, script_dir, bin_dir]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        # Minimal script to emulate successful VM provisioning.
        create_script = script_dir / "create-talos-vms.sh"
        create_script.write_text("#!/bin/bash\nset -euo pipefail\necho create-ok\n")
        create_script.chmod(0o755)

        # Bootstrap script is not used in this test but kept for completeness.
        bootstrap_script = script_dir / "bootstrap-talos.sh"
        bootstrap_script.write_text("#!/bin/bash\nset -euo pipefail\necho bootstrap-ok\n")
        bootstrap_script.chmod(0o755)

        cluster = {
            "id": "cluster_test",
            "name": "demo",
            "controlplane_count": 1,
            "worker_count": 1,
            "cpu_cores": 2,
            "memory_mb": 4096,
            "disk_gb": 20,
            "bridge": "vmbr0",
            "start_vmid": 200,
            "start_ip": "192.168.1.51",
            "vip_ip": "192.168.1.50",
            "metadata": {
                "proxmox_node": "pve",
                "storage_pool": "local-lvm",
            },
        }

        job = {
            "id": "job_test",
            "type": "create_cluster",
            "cluster_id": "cluster_test",
            "status": "pending",
            "step": "queued",
            "payload": cluster,
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (jobs / "job_test.json").write_text(json.dumps(job))
        (pending / "job_test.json").write_text(json.dumps({
            "id": "job_test",
            "type": "create_cluster",
            "cluster_id": "cluster_test",
            "payload": cluster,
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["KUBECTL_VERSION"] = "v1.30.0"
        env["HELM_VERSION"] = "v3.15.4"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"

        proc = subprocess.Popen(
            ["node", "manager-worker/src/worker.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            completed_file = data / "queue" / "completed" / "job_test.json"
            _wait_until(lambda: completed_file.exists())

            updated_job = json.loads((jobs / "job_test.json").read_text())
            assert updated_job["status"] == "succeeded"
            assert updated_job["step"] == "completed"

            log_text = (logs / "job_test.log").read_text()
            assert "running job type=create_cluster" in log_text
            assert "job completed" in log_text
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_exits_on_tool_version_mismatch():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"

        for d in [data / "queue" / "pending", data / "jobs", data / "logs", data / "clusters", workspace, bin_dir]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["KUBECTL_VERSION"] = "v1.31.0"
        env["HELM_VERSION"] = "v3.15.4"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"

        proc = subprocess.Popen(
            ["node", "manager-worker/src/worker.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        stdout, stderr = proc.communicate(timeout=10)
        assert proc.returncode != 0
        assert "tool version mismatch" in stdout or "tool version mismatch" in stderr
