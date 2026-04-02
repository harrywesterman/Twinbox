import json
import os
import subprocess
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def _read_repo_pinned_defaults():
    values = {}
    for raw_line in (REPO_ROOT / "config" / "pinned-defaults.sh").read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


PINNED_DEFAULTS = _read_repo_pinned_defaults()
PINNED_TALOS_VERSION = PINNED_DEFAULTS["PINNED_TALOS_VERSION"]
PINNED_OPENTOFU_VERSION = PINNED_DEFAULTS["PINNED_OPENTOFU_VERSION"]
PINNED_KUBECTL_VERSION = PINNED_DEFAULTS["PINNED_KUBECTL_VERSION"]
PINNED_HELM_VERSION = PINNED_DEFAULTS["PINNED_HELM_VERSION"]


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
        f"#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo 'Client: {PINNED_TALOS_VERSION}'; exit 0; fi\nexit 0\n",
    )
    _write_fake_tool(
        bin_dir / "tofu",
        f"#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo 'OpenTofu {PINNED_OPENTOFU_VERSION}'; exit 0; fi\nexit 0\n",
    )
    _write_fake_tool(
        bin_dir / "kubectl",
        f"#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo '{{\"clientVersion\":{{\"gitVersion\":\"{PINNED_KUBECTL_VERSION}\"}}}}'; exit 0; fi\nexit 0\n",
    )
    _write_fake_tool(
        bin_dir / "helm",
        f"#!/bin/bash\nif [[ \"$1\" == \"version\" ]]; then echo '{PINNED_HELM_VERSION}+gabcdef'; exit 0; fi\nexit 0\n",
    )


def _write_pinned_defaults(
    workspace: Path,
    talos_version: str = PINNED_TALOS_VERSION,
    opentofu_version: str = PINNED_OPENTOFU_VERSION,
    kubectl_version: str = PINNED_KUBECTL_VERSION,
    helm_version: str = PINNED_HELM_VERSION,
):
    config_dir = workspace / "config"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "pinned-defaults.sh").write_text(
        "\n".join(
            [
                f"PINNED_TALOS_VERSION={talos_version}",
                f"PINNED_OPENTOFU_VERSION={opentofu_version}",
                f"PINNED_KUBECTL_VERSION={kubectl_version}",
                f"PINNED_HELM_VERSION={helm_version}",
                "PINNED_PROXMOX_ISO_STORAGE=local",
                "",
            ],
        ),
    )


def _global_step_state(data: Path, step_id: str) -> Path:
    return data / "step-state" / "global" / f"{step_id}.json"


def _cluster_step_state(data: Path, cluster_id: str, step_id: str) -> Path:
    return data / "step-state" / "clusters" / cluster_id / f"{step_id}.json"


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
        create_script = script_dir / "apply-cluster.sh"
        create_script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "cat > \"$MANAGER_DATA_DIR/child-env.txt\" <<EOF\n"
            "PROXMOX_HOST=${PROXMOX_HOST-}\n"
            "PROXMOX_PORT=${PROXMOX_PORT-}\n"
            "PROXMOX_USER=${PROXMOX_USER-}\n"
            "PROXMOX_PASSWORD=${PROXMOX_PASSWORD-}\n"
            "TF_VAR_proxmox_endpoint=${TF_VAR_proxmox_endpoint-}\n"
            "TF_VAR_proxmox_username=${TF_VAR_proxmox_username-}\n"
            "TF_VAR_proxmox_password=${TF_VAR_proxmox_password-}\n"
            "EOF\n"
            "echo create-ok\n",
        )
        create_script.chmod(0o755)

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
            "node_prefix_length": 24,
            "gateway_ip": "192.168.1.1",
            "dns_servers": ["1.1.1.1", "8.8.8.8"],
            "dns_domain": "cluster.internal",
            "metadata": {
                "proxmox_node": "pve",
                "storage_pool": "local-lvm",
                "file_datastore": "local",
            },
        }

        job = {
            "id": "job_test",
            "type": "apply_cluster",
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
            "type": "apply_cluster",
            "cluster_id": "cluster_test",
            "payload": cluster,
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["TWINBOX_SECRET_BACKEND"] = "env"
        env["PROXMOX_HOST"] = "192.168.1.10"
        env["PROXMOX_PORT"] = "8006"
        env["PROXMOX_USER"] = "root@pam"
        env["PROXMOX_PASSWORD"] = "super-secret"

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
            child_env_file = data / "child-env.txt"
            _wait_until(lambda: completed_file.exists())
            _wait_until(lambda: child_env_file.exists())

            updated_job = json.loads((jobs / "job_test.json").read_text())
            assert updated_job["status"] == "succeeded"
            assert updated_job["step"] == "completed"

            child_env = child_env_file.read_text()
            assert "PROXMOX_HOST=192.168.1.10" in child_env
            assert "PROXMOX_PORT=8006" in child_env
            assert "PROXMOX_USER=root@pam" in child_env
            assert "PROXMOX_PASSWORD=" in child_env
            assert "PROXMOX_PASSWORD=super-secret" not in child_env
            assert "TF_VAR_proxmox_endpoint=https://192.168.1.10:8006" in child_env
            assert "TF_VAR_proxmox_username=root@pam" in child_env
            assert "TF_VAR_proxmox_password=super-secret" in child_env

            log_text = (logs / "job_test.log").read_text()
            assert "running job type=apply_cluster" in log_text
            assert "--node-prefix-length 24" in log_text
            assert "--gateway-ip 192.168.1.1" in log_text
            assert "--dns-servers 1.1.1.1,8.8.8.8" in log_text
            assert "--dns-domain cluster.internal" in log_text
            assert "--file-datastore local" in log_text
            assert "job completed" in log_text
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_recovers_orphaned_running_run_step_job_on_startup():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"

        for d in [
            data / "queue" / "running",
            data / "queue" / "completed",
            data / "jobs",
            data / "logs",
            data / "clusters",
            workspace,
            bin_dir,
        ]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        payload = {
            "step_id": "provision-nodes",
            "step_type": "action",
            "inputs": {"name": "demo"},
            "runner": {
                "kind": "script",
                "script": "categories/talos-cluster/steps/provision-nodes/run.sh",
            },
            "context": {
                "cluster": {
                    "id": "cluster_test",
                    "name": "demo",
                }
            },
        }
        job = {
            "id": "job_orphaned",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "status": "running",
            "step": "started",
            "payload": payload,
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": "2026-01-01T00:00:01Z",
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (data / "jobs" / "job_orphaned.json").write_text(json.dumps(job))
        (data / "queue" / "running" / "job_orphaned.json").write_text(json.dumps({
            "id": "job_orphaned",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "payload": payload,
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["TWINBOX_SECRET_BACKEND"] = "env"
        env["PROXMOX_HOST"] = "192.168.1.10"
        env["PROXMOX_PORT"] = "8006"
        env["PROXMOX_USER"] = "root@pam"
        env["PROXMOX_PASSWORD"] = "super-secret"

        proc = subprocess.Popen(
            ["node", "manager-worker/src/worker.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            _wait_until(lambda: (data / "queue" / "completed" / "job_orphaned.json").exists())

            updated_job = json.loads((data / "jobs" / "job_orphaned.json").read_text())
            assert updated_job["status"] == "failed"
            assert updated_job["step"] == "failed"
            assert updated_job["error"] == "worker restarted while job was running"

            step_state = json.loads(_cluster_step_state(data, "cluster_test", "provision-nodes").read_text())
            assert step_state["status"] == "failed"
            assert step_state["cluster_id"] == "cluster_test"
            assert step_state["error"] == "worker restarted while job was running"
            assert step_state["last_job_id"] == "job_orphaned"

            log_text = (data / "logs" / "job_orphaned.log").read_text()
            assert "job failed: worker restarted while job was running" in log_text
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_materializes_secret_bundle_files_and_cleans_up():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"
        pending = data / "queue" / "pending"
        jobs = data / "jobs"
        logs = data / "logs"
        clusters = data / "clusters"
        script_dir = workspace / "categories" / "management-vm" / "steps" / "secret-file-check"

        for d in [pending, jobs, logs, clusters, script_dir, bin_dir]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        secret_script = script_dir / "apply.sh"
        secret_script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "test -f \"$TALOS_SECRETS_FILE\"\n"
            "printf '%s' \"$(cat \"$TALOS_SECRETS_FILE\")\" > \"$MANAGER_DATA_DIR/secret-file-content.txt\"\n"
            "printf '%s' \"$TALOS_SECRETS_FILE\" > \"$MANAGER_DATA_DIR/secret-file-path.txt\"\n"
            "printf '{\"materialized\":true}' > \"$STEP_RESULT_FILE\"\n",
        )
        secret_script.chmod(0o755)

        job = {
            "id": "job_secret_file",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "secret-file-check",
                "step_type": "config",
                "inputs": {"enabled": True},
                "runner": {
                    "kind": "script",
                    "script": "categories/management-vm/steps/secret-file-check/apply.sh",
                },
                "context": {
                    "cluster": {
                        "id": "cluster_test",
                        "name": "demo",
                    }
                },
                "secret_bundle": {
                    "files": {
                        "TALOS_SECRETS_FILE": {
                            "scope": "global",
                            "item": "proxmox",
                            "field": "password",
                            "format": "file",
                        }
                    }
                },
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (jobs / "job_secret_file.json").write_text(json.dumps(job))
        (pending / "job_secret_file.json").write_text(json.dumps({
            "id": "job_secret_file",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "payload": job["payload"],
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["TWINBOX_SECRET_BACKEND"] = "env"
        env["PROXMOX_HOST"] = "192.168.1.10"
        env["PROXMOX_PORT"] = "8006"
        env["PROXMOX_USER"] = "root@pam"
        env["PROXMOX_PASSWORD"] = "super-secret"

        proc = subprocess.Popen(
            ["node", "manager-worker/src/worker.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            _wait_until(lambda: (data / "queue" / "completed" / "job_secret_file.json").exists())

            updated_job = json.loads((jobs / "job_secret_file.json").read_text())
            assert updated_job["status"] == "succeeded"

            secret_content = (data / "secret-file-content.txt").read_text()
            secret_path = (data / "secret-file-path.txt").read_text()
            assert secret_content == "super-secret"
            assert secret_path
            assert not Path(secret_path).exists()
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
        _write_pinned_defaults(workspace, kubectl_version="v1.31.0")

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
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


def test_worker_processes_run_step_config_job_and_persists_outputs():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"
        host_cron_dir = root / "host-cron"

        for d in [
            data / "queue" / "pending",
            data / "jobs",
            data / "logs",
            data / "clusters",
            data / "step-state",
            workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates",
            host_cron_dir,
            bin_dir,
        ]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        script = workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates" / "apply.sh"
        script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "echo config-step-running\n"
            "touch \"$TWINBOX_HOST_CRON_DIR/twinbox-managed-test\"\n"
            "printf '{\"applied\":true}' > \"$STEP_RESULT_FILE\"\n"
        )
        script.chmod(0o755)

        job = {
            "id": "job_config",
            "type": "run_step",
            "cluster_id": None,
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "configure-automatic-updates",
                "step_type": "config",
                "inputs": {"enabled": True, "schedule_hour": 3, "schedule_minute": 17},
                "runner": {
                    "kind": "script",
                    "script": "categories/management-vm/steps/configure-automatic-updates/apply.sh",
                },
                "context": {},
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (data / "jobs" / "job_config.json").write_text(json.dumps(job))
        (data / "queue" / "pending" / "job_config.json").write_text(json.dumps({
            "id": "job_config",
            "type": "run_step",
            "cluster_id": None,
            "payload": job["payload"],
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["TWINBOX_HOST_CRON_DIR"] = str(host_cron_dir)
        env["TWINBOX_HOST_REPO_ROOT"] = "/opt/twinbox-demo"

        proc = subprocess.Popen(
            ["node", "manager-worker/src/worker.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            _wait_until(lambda: (data / "queue" / "completed" / "job_config.json").exists())

            updated_job = json.loads((data / "jobs" / "job_config.json").read_text())
            assert updated_job["status"] == "succeeded"

            step_state = json.loads(_global_step_state(data, "configure-automatic-updates").read_text())
            assert step_state["status"] == "configured"
            assert step_state["inputs"]["enabled"] is True
            assert step_state["outputs"] == {"applied": True}
            assert step_state["last_job_id"] == "job_config"

            assert (host_cron_dir / "twinbox-managed-test").exists()
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_processes_run_step_action_job_and_records_cluster_context():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"

        for d in [
            data / "queue" / "pending",
            data / "jobs",
            data / "logs",
            data / "clusters",
            data / "step-state",
            workspace / "categories" / "talos-cluster" / "steps" / "provision-nodes",
            bin_dir,
        ]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        script = workspace / "categories" / "talos-cluster" / "steps" / "provision-nodes" / "run.sh"
        script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "cluster_id=$(printf '%s' \"$STEP_CONTEXT_JSON\" | jq -r '.cluster.id')\n"
            "echo action-step-running \"$cluster_id\"\n"
            "printf '{\"cluster_id\":\"%s\"}' \"$cluster_id\" > \"$STEP_RESULT_FILE\"\n"
        )
        script.chmod(0o755)

        job = {
            "id": "job_action",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "provision-nodes",
                "step_type": "action",
                "inputs": {"name": "demo"},
                "runner": {
                    "kind": "script",
                    "script": "categories/talos-cluster/steps/provision-nodes/run.sh",
                },
                "context": {
                    "cluster": {
                        "id": "cluster_test",
                        "name": "demo",
                    }
                },
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (data / "jobs" / "job_action.json").write_text(json.dumps(job))
        (data / "queue" / "pending" / "job_action.json").write_text(json.dumps({
            "id": "job_action",
            "type": "run_step",
            "cluster_id": "cluster_test",
            "payload": job["payload"],
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
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
            _wait_until(lambda: (data / "queue" / "completed" / "job_action.json").exists())

            updated_job = json.loads((data / "jobs" / "job_action.json").read_text())
            assert updated_job["status"] == "succeeded"

            step_state = json.loads(_cluster_step_state(data, "cluster_test", "provision-nodes").read_text())
            assert step_state["status"] == "succeeded"
            assert step_state["cluster_id"] == "cluster_test"
            assert step_state["outputs"] == {"cluster_id": "cluster_test"}
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_marks_run_step_job_failed_when_script_fails():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"

        for d in [
            data / "queue" / "pending",
            data / "jobs",
            data / "logs",
            data / "clusters",
            data / "step-state",
            workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates",
            bin_dir,
        ]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        script = workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates" / "apply.sh"
        script.write_text("#!/bin/bash\nset -euo pipefail\necho boom >&2\nexit 42\n")
        script.chmod(0o755)

        job = {
            "id": "job_failed_step",
            "type": "run_step",
            "cluster_id": None,
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "configure-automatic-updates",
                "step_type": "config",
                "inputs": {"enabled": True},
                "runner": {
                    "kind": "script",
                    "script": "categories/management-vm/steps/configure-automatic-updates/apply.sh",
                },
                "context": {},
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (data / "jobs" / "job_failed_step.json").write_text(json.dumps(job))
        (data / "queue" / "pending" / "job_failed_step.json").write_text(json.dumps({
            "id": "job_failed_step",
            "type": "run_step",
            "cluster_id": None,
            "payload": job["payload"],
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
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
            _wait_until(lambda: (data / "queue" / "completed" / "job_failed_step.json").exists())

            updated_job = json.loads((data / "jobs" / "job_failed_step.json").read_text())
            assert updated_job["status"] == "failed"
            assert updated_job["error"] == "command exited with code 42: boom"

            step_state = json.loads(_global_step_state(data, "configure-automatic-updates").read_text())
            assert step_state["status"] == "failed"
            assert step_state["error"] == "command exited with code 42: boom"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_includes_recent_script_output_in_failed_run_step_error():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"

        for d in [
            data / "queue" / "pending",
            data / "jobs",
            data / "logs",
            data / "clusters",
            data / "step-state",
            workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates",
            bin_dir,
        ]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        script = workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates" / "apply.sh"
        script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "echo first failure line >&2\n"
            "echo second failure line >&2\n"
            "exit 7\n"
        )
        script.chmod(0o755)

        job = {
            "id": "job_failed_step_output",
            "type": "run_step",
            "cluster_id": None,
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "configure-automatic-updates",
                "step_type": "config",
                "inputs": {"enabled": True},
                "runner": {
                    "kind": "script",
                    "script": "categories/management-vm/steps/configure-automatic-updates/apply.sh",
                },
                "context": {},
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (data / "jobs" / "job_failed_step_output.json").write_text(json.dumps(job))
        (data / "queue" / "pending" / "job_failed_step_output.json").write_text(json.dumps({
            "id": "job_failed_step_output",
            "type": "run_step",
            "cluster_id": None,
            "payload": job["payload"],
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
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
            _wait_until(lambda: (data / "queue" / "completed" / "job_failed_step_output.json").exists())

            updated_job = json.loads((data / "jobs" / "job_failed_step_output.json").read_text())
            assert updated_job["status"] == "failed"
            assert "command exited with code 7" in updated_job["error"]
            assert "second failure line" in updated_job["error"]

            step_state = json.loads(_global_step_state(data, "configure-automatic-updates").read_text())
            assert step_state["status"] == "failed"
            assert "second failure line" in step_state["error"]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_worker_cancels_running_run_step_job_when_job_status_changes():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        bin_dir = root / "bin"
        marker_file = data / "started.txt"

        for d in [
            data / "queue" / "pending",
            data / "queue" / "running",
            data / "queue" / "completed",
            data / "jobs",
            data / "logs",
            data / "clusters",
            data / "step-state",
            workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates",
            bin_dir,
        ]:
            d.mkdir(parents=True, exist_ok=True)

        _prepare_fake_toolchain(bin_dir)
        _write_pinned_defaults(workspace)

        script = workspace / "categories" / "management-vm" / "steps" / "configure-automatic-updates" / "apply.sh"
        script.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            f"touch \"{marker_file}\"\n"
            "trap 'echo stopping >&2' TERM\n"
            "while true; do sleep 1; done\n",
        )
        script.chmod(0o755)

        job = {
            "id": "job_cancel_running",
            "type": "run_step",
            "cluster_id": None,
            "status": "pending",
            "step": "queued",
            "payload": {
                "step_id": "configure-automatic-updates",
                "step_type": "config",
                "inputs": {"enabled": True},
                "runner": {
                    "kind": "script",
                    "script": "categories/management-vm/steps/configure-automatic-updates/apply.sh",
                },
                "context": {},
            },
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "started_at": None,
            "finished_at": None,
            "result": None,
            "error": None,
        }
        (data / "jobs" / "job_cancel_running.json").write_text(json.dumps(job))
        (data / "queue" / "pending" / "job_cancel_running.json").write_text(json.dumps({
            "id": "job_cancel_running",
            "type": "run_step",
            "cluster_id": None,
            "payload": job["payload"],
            "queued_at": "2026-01-01T00:00:00Z",
        }))

        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data)
        env["WORKSPACE_ROOT"] = str(workspace)
        env["WORKER_POLL_MS"] = "100"
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["TWINBOX_SECRET_BACKEND"] = "env"

        proc = subprocess.Popen(
            ["node", "manager-worker/src/worker.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            _wait_until(lambda: marker_file.exists())
            _wait_until(lambda: json.loads((data / "jobs" / "job_cancel_running.json").read_text())["status"] == "running")

            job_data = json.loads((data / "jobs" / "job_cancel_running.json").read_text())
            job_data["status"] = "cancel_requested"
            job_data["step"] = "cancel_requested"
            job_data["updated_at"] = "2026-01-01T00:00:05Z"
            (data / "jobs" / "job_cancel_running.json").write_text(json.dumps(job_data))

            _wait_until(lambda: (data / "queue" / "completed" / "job_cancel_running.json").exists())

            updated_job = json.loads((data / "jobs" / "job_cancel_running.json").read_text())
            assert updated_job["status"] == "canceled"
            assert updated_job["step"] == "canceled"

            step_state = json.loads(_global_step_state(data, "configure-automatic-updates").read_text())
            assert step_state["status"] == "canceled"
            assert step_state["last_job_id"] == "job_cancel_running"

            log_text = (data / "logs" / "job_cancel_running.log").read_text()
            assert "cancel requested" in log_text
            assert "job canceled" in log_text
        finally:
            proc.terminate()
            proc.wait(timeout=5)
