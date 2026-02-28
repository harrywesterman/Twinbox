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


def test_worker_processes_pending_job_to_completed():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data = root / "data"
        workspace = root / "workspace"
        pending = data / "queue" / "pending"
        jobs = data / "jobs"
        logs = data / "logs"
        clusters = data / "clusters"
        script_dir = workspace / "scripts" / "manager"

        for d in [pending, jobs, logs, clusters, script_dir]:
            d.mkdir(parents=True, exist_ok=True)

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
                "iso_storage": "local",
                "talos_iso_file": "talos-v1.7.4.iso",
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
