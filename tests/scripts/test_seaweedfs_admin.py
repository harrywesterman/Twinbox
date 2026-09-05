import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_admin_reconciliation_preserves_credentials_and_uses_guest_address(tmp_path):
    directory = tmp_path / "secrets/cluster/test/backup-storage"
    directory.mkdir(parents=True)
    profile = directory / "metadata.json"
    profile.write_text(
        json.dumps(
            {
                "mode": "managed-seaweedfs",
                "vm": {
                    "ip_address": "backup.example.test",
                    "ssh_private_key": "/test/guest-key",
                    "status": "ready",
                },
            }
        )
    )
    binaries = tmp_path / "bin"
    binaries.mkdir()
    for command in ("ssh", "scp"):
        file = binaries / command
        file.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\ncat >/dev/null\n')
        file.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{binaries}:{os.environ['PATH']}",
        "TWINBOX_BOOTSTRAP_DIR": str(tmp_path),
        "TWINBOX_CLUSTER_ID": "test",
        "CALL_LOG": str(tmp_path / "calls"),
    }
    script = ROOT / "scripts/manager/configure-seaweedfs-admin.sh"
    subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True)
    credentials = (directory / "admin.json").read_text()
    subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True)
    assert (directory / "admin.json").read_text() == credentials
    assert json.loads(profile.read_text())["admin"]["url"] == "https://backup.example.test:8443"
    assert json.loads(profile.read_text())["vm"]["status"] == "ready"
    calls = (tmp_path / "calls").read_text()
    assert "twinbox@backup.example.test" in calls
    assert "/test/guest-key" in calls
    assert json.loads(credentials)["password"] not in calls
