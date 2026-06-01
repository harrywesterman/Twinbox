import json
import os
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_longhorn_uses_seaweedfs_backup_target_and_recurring_jobs():
    app_text = (REPO_ROOT / "gitops" / "apps" / "longhorn.yaml").read_text(encoding="utf-8")
    values_text = (REPO_ROOT / "gitops" / "values" / "longhorn.yaml").read_text(encoding="utf-8")
    script_text = (REPO_ROOT / "scripts" / "manager" / "install-longhorn-storage.sh").read_text(
        encoding="utf-8"
    )

    assert "__LONGHORN_VALUES__" in app_text
    assert "recurringJobSelector:" in values_text
    assert 'jobList: \'[{"name":"default","isGroup":true}]\'' in values_text
    assert "defaultBackupStore:" in values_text
    assert "backupTarget: __LONGHORN_BACKUP_TARGET__" in values_text
    assert "backupTargetCredentialSecret: __LONGHORN_BACKUP_SECRET_NAME__" in values_text
    assert '--from-literal=AWS_ENDPOINTS="$SEAWEEDFS_ENDPOINT"' in script_text
    assert 'LONGHORN_BACKUP_TARGET="s3://${SEAWEEDFS_BUCKET}@${SEAWEEDFS_REGION}/"' in script_text
    assert "kind: RecurringJob" in script_text
    assert "name: twinbox-snapshot-4h" in script_text
    assert 'cron: "0 */4 * * *"' in script_text
    assert "retain: 6" in script_text
    assert "name: twinbox-backup-daily" in script_text
    assert 'cron: "0 1 * * *"' in script_text
    assert "retain: 14" in script_text
    assert "nodeDrainPolicy: allow-if-replica-is-stopped" in values_text
    assert "detachManuallyAttachedVolumesWhenCordoned: true" in values_text


def test_longhorn_maintenance_runbook_documents_the_upgrade_flow():
    doc_text = (REPO_ROOT / "docs" / "longhorn-maintenance.md").read_text(encoding="utf-8")

    assert "allow-if-replica-is-stopped" in doc_text
    assert "detachManuallyAttachedVolumesWhenCordoned" in doc_text
    assert "Upgrade Flow" in doc_text
    assert "Preflight Checks" in doc_text
    assert "one Talos node at a time" in doc_text


def test_velero_has_daily_cluster_backup_schedule_with_30_day_ttl():
    values_text = (REPO_ROOT / "gitops" / "values" / "velero.yaml").read_text(encoding="utf-8")

    assert "schedules:" in values_text
    assert "twinbox-daily:" in values_text
    assert 'schedule: "0 3 * * *"' in values_text
    assert "ttl: 720h" in values_text
    assert "storageLocation: default" in values_text


def test_cloudnativepg_clusters_use_seaweedfs_and_14_day_retention():
    database_root = REPO_ROOT / "gitops" / "databases"
    cluster_files = [
        path for path in database_root.glob("*/cluster.yaml") if path.parent.name != "_template"
    ]
    assert cluster_files

    for path in cluster_files:
        text = path.read_text(encoding="utf-8")
        assert 'retentionPolicy: "14d"' in text, path
        assert "barmanObjectStore:" in text, path
        assert "destinationPath: s3://twinbox-velero/" in text, path
        assert "endpointURL: http://seaweedfs.longhorn-system.svc.cluster.local:8333" in text, path
        assert "name: seaweedfs-backup-credentials" in text, path

    for path in database_root.glob("*/scheduled-backup.yaml"):
        text = path.read_text(encoding="utf-8")
        assert 'schedule: "0 2 * * *"' in text, path


def test_management_vm_backup_installs_host_cron_without_embedding_secrets():
    script_text = (REPO_ROOT / "scripts" / "manager" / "install-management-backup.sh").read_text(
        encoding="utf-8"
    )
    step_text = (
        REPO_ROOT
        / "categories"
        / "talos-cluster"
        / "steps"
        / "install-management-backup"
        / "step.yaml"
    ).read_text(encoding="utf-8")

    assert "management-backup.json" in script_text
    assert "restic_password" in script_text
    assert "talosctl etcd snapshot" in script_text
    assert '--talosconfig "$talosconfig"' in script_text
    assert 'restic -r "$repo"' in script_text
    assert "management-vm/%s" in script_text
    assert "restic_repo etcd" in script_text
    assert "restic_repo opt-twinbox" in script_text
    assert '--exclude "${host_root}/seaweedfs/data"' in script_text
    assert "--keep-daily=${retention_days}" in script_text
    assert "17 2 * * * root ${RUNTIME_SCRIPT} etcd" in script_text
    assert "47 2 * * * root ${RUNTIME_SCRIPT} opt-twinbox" in script_text
    assert '--arg password "$password"' in script_text
    cron_template = script_text.split('install -m 0644 /dev/stdin "$CRON_FILE" <<EOF', 1)[1]
    cron_template = cron_template.split("EOF", 1)[0]
    assert "password" not in cron_template.lower()
    assert "AWS_SECRET_ACCESS_KEY" not in cron_template

    assert "id: install-management-backup" in step_text
    assert "TWINBOX_TALOSCONFIG_FILE" in step_text
    assert "attachment: talosconfig" in step_text


def test_velero_backup_uses_portable_management_ip_resolution():
    script_text = (REPO_ROOT / "scripts" / "manager" / "install-velero-backup.sh").read_text(
        encoding="utf-8"
    )
    helper_text = (REPO_ROOT / "scripts" / "manager" / "management-ip.sh").read_text(
        encoding="utf-8"
    )

    assert "management-ip.sh" in script_text
    assert "hostname -I" not in script_text
    assert "resolve_management_vm_ip()" in helper_text
    assert "hostname -I" not in helper_text
    assert "python3 - <<'PY'" in helper_text
    assert "ip route get 1.1.1.1" in helper_text


def test_management_tools_install_restic_for_host_backup_jobs():
    text = (REPO_ROOT / "scripts" / "install-management-tools.sh").read_text(encoding="utf-8")

    assert "install_restic()" in text
    assert "apt-get install -y restic >/dev/null" in text
    assert "command -v restic >/dev/null 2>&1 || fail" in text
    assert "install_restic" in text


def test_management_vm_backup_install_uses_cluster_state_before_step_context():
    script_path = REPO_ROOT / "scripts" / "manager" / "install-management-backup.sh"

    def _write_script(path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bin_dir = root / "bin"
        host_repo_root = root / "opt" / "twinbox"
        bootstrap_root = host_repo_root / "bootstrap"
        manager_data_root = host_repo_root / "manager-data"
        cluster_dir = manager_data_root / "clusters"
        secrets_dir = bootstrap_root / "secrets" / "global"
        cluster_secrets_dir = (
            bootstrap_root / "secrets" / "cluster" / "cluster-test" / "talosconfig"
        )
        host_cron_dir = root / "etc" / "cron.d"

        for directory in [
            bin_dir,
            cluster_dir,
            secrets_dir,
            cluster_secrets_dir,
            host_cron_dir,
        ]:
            directory.mkdir(parents=True, exist_ok=True)

        cluster_state = {
            "id": "cluster-test",
            "discovered_controlplane_ips": ["192.168.1.11"],
            "controlplane_ips": ["192.168.1.12"],
        }
        (cluster_dir / "cluster-test.json").write_text(
            json.dumps(cluster_state, indent=2) + "\n",
            encoding="utf-8",
        )
        (secrets_dir / "velero.json").write_text(
            json.dumps(
                {
                    "endpoint": "http://seaweedfs.longhorn-system.svc.cluster.local:8333",
                    "bucket": "twinbox-velero",
                    "region": "seaweedfs",
                    "username": "velero",
                    "password": "super-secret",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (cluster_secrets_dir / "talosconfig").write_text("talosconfig-data\n", encoding="utf-8")

        _write_script(
            bin_dir / "restic",
            """#!/usr/bin/env bash
set -euo pipefail
exit 0
""",
        )
        _write_script(
            bin_dir / "talosctl",
            """#!/usr/bin/env bash
set -euo pipefail
exit 0
""",
        )
        _write_script(
            bin_dir / "openssl",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" ]]; then
  printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  exit 0
fi
exit 0
""",
        )

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["HOST_REPO_ROOT"] = str(host_repo_root)
        env["TWINBOX_HOST_REPO_ROOT"] = str(host_repo_root)
        env["TWINBOX_BOOTSTRAP_DIR"] = str(bootstrap_root)
        env["TWINBOX_HOST_CRON_DIR"] = str(host_cron_dir)
        env["TWINBOX_CLUSTER_ID"] = "cluster-test"
        env["TWINBOX_TALOSCONFIG_FILE"] = str(cluster_secrets_dir / "talosconfig")
        env["MANAGEMENT_VM_IP"] = "192.168.1.20"
        env["STEP_CONTEXT_JSON"] = "{not-valid-json"

        result = subprocess.run(
            ["bash", str(script_path)],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        assert result.returncode == 0, result.stderr

        config_file = bootstrap_root / "secrets" / "global" / "management-backup.json"
        cron_file = host_cron_dir / "twinbox-management-backup"
        runtime_script = bootstrap_root / "bin" / "twinbox-management-backup.sh"

        assert config_file.exists()
        assert cron_file.exists()
        assert runtime_script.exists()

        config = json.loads(config_file.read_text(encoding="utf-8"))
        cron_text = cron_file.read_text(encoding="utf-8")
        runtime_text = runtime_script.read_text(encoding="utf-8")

        assert config["cluster_id"] == "cluster-test"
        assert config["controlplane_ip"] == "192.168.1.11"
        assert config["endpoint"] == "http://192.168.1.20:8333"
        assert config["talosconfig"] == str(cluster_secrets_dir / "talosconfig")
        assert config["host_root"] == str(host_repo_root)
        assert config["retention_days"] == 30
        assert config["exclude_paths"] == [str(host_repo_root / "seaweedfs" / "data")]

        assert "17 2 * * * root ${RUNTIME_SCRIPT} etcd" not in cron_text
        assert (
            f"17 2 * * * root {bootstrap_root}/bin/twinbox-management-backup.sh etcd" in cron_text
        )
        assert (
            f"47 2 * * * root {bootstrap_root}/bin/twinbox-management-backup.sh opt-twinbox"
            in cron_text
        )

        assert "restic_repo etcd" in runtime_text
        assert "restic_repo opt-twinbox" in runtime_text
        assert 'talosctl etcd snapshot "$snapshot_path"' in runtime_text
        assert '--exclude "${host_root}/seaweedfs/data"' in runtime_text
