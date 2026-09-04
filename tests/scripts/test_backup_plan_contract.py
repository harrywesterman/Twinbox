import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_longhorn_uses_cluster_backup_profile_and_recurring_jobs():
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
    assert '--from-literal=AWS_ENDPOINTS="$BACKUP_S3_ENDPOINT"' in script_text
    assert "load_backup_storage_profile longhorn" in script_text
    assert 'LONGHORN_BACKUP_TARGET="s3://${BACKUP_S3_BUCKET}@${BACKUP_S3_REGION}/"' in script_text
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


def test_cloudnativepg_clusters_use_rendered_cluster_s3_profile_and_14_day_retention():
    database_root = REPO_ROOT / "gitops" / "databases"
    shared_kustomization_text = (database_root / "shared" / "kustomization.yaml").read_text(
        encoding="utf-8"
    )
    cluster_files = [
        path for path in database_root.glob("*/cluster.yaml") if path.parent.name != "_template"
    ]
    assert cluster_files
    assert "seaweedfs-backup-credentials.yaml" not in shared_kustomization_text
    renderer_text = (REPO_ROOT / "scripts/manager/render-database-backup-stores.sh").read_text()
    install_text = (
        REPO_ROOT / "categories/talos-cluster/steps/install-cloudnativepg/run.sh"
    ).read_text()
    assert "load_backup_storage_profile databases" in renderer_text
    assert "twinbox/cluster/${cluster_id}/backup-storage" in renderer_text
    assert "render-database-backup-stores.sh" in install_text

    for path in cluster_files:
        text = path.read_text(encoding="utf-8")
        cluster_name = path.parent.name
        objectstore_text = (path.parent / "objectstore.yaml").read_text(encoding="utf-8")
        kustomization = path.parent / "kustomization.yaml"
        kustomization_text = (
            kustomization.read_text(encoding="utf-8") if kustomization.exists() else ""
        )

        assert "barmanObjectStore:" not in text, path
        assert "plugins:" in text, path
        assert "name: barman-cloud.cloudnative-pg.io" in text, path
        assert "isWALArchiver: true" in text, path
        assert f"barmanObjectName: {cluster_name}-db-objectstore" in text, path
        assert f"serverName: {cluster_name}-db" in text, path

        assert "apiVersion: barmancloud.cnpg.io/v1" in objectstore_text, path
        assert "kind: ObjectStore" in objectstore_text, path
        assert 'retentionPolicy: "14d"' in objectstore_text, path
        assert "destinationPath:" in objectstore_text, path
        assert "endpointURL:" in objectstore_text, path
        assert "name: seaweedfs-backup-credentials" in objectstore_text, path
        if kustomization.exists():
            assert "objectstore.yaml" not in kustomization_text, path

    schedule_re = re.compile(r'^\s*schedule: "0 0 2 \* \* ([1-6])"$', re.MULTILINE)
    days_used = set()
    for path in database_root.glob("*/scheduled-backup.yaml"):
        text = path.read_text(encoding="utf-8")
        assert "method: plugin" in text, path
        assert "pluginConfiguration:" in text, path
        assert "name: barman-cloud.cloudnative-pg.io" in text, path
        match = schedule_re.search(text)
        assert match, f"expected a weekly base backup schedule in {path}"
        days_used.add(int(match.group(1)))

    expected_days = {1, 2, 3, 4, 5, 6}
    assert days_used == expected_days, (
        f"expected staggered weekly base backups, got {sorted(days_used)}"
    )


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

    assert "management-backup/metadata.json" in script_text
    assert "restic_password" in script_text
    assert "talosctl etcd snapshot" in script_text
    assert '--talosconfig "$talosconfig"' in script_text
    assert 'restic -r "$repo"' in script_text
    assert "management-vm/%s" in script_text
    assert "restic_repo etcd" in script_text
    assert "restic_repo opt-twinbox" in script_text
    assert '--exclude "${host_root}/seaweedfs/data"' not in script_text
    assert "--keep-daily=${retention_days}" in script_text
    assert "TWINBOX_MANAGEMENT_BACKUP_CONFIG=${MANAGEMENT_BACKUP_FILE}" in script_text
    assert '--arg password "$password"' in script_text
    cron_template = script_text.split('install -m 0644 /dev/stdin "$CRON_FILE" <<EOF', 1)[1]
    cron_template = cron_template.split("EOF", 1)[0]
    assert "password" not in cron_template.lower()
    assert "AWS_SECRET_ACCESS_KEY" not in cron_template

    assert "id: install-management-backup" in step_text
    assert "TWINBOX_TALOSCONFIG_FILE" in step_text
    assert "attachment: talosconfig" in step_text


def test_velero_backup_uses_cluster_backup_profile_without_management_ip_fallback():
    script_text = (REPO_ROOT / "scripts" / "manager" / "install-velero-backup.sh").read_text(
        encoding="utf-8"
    )
    assert "backup-storage-profile.sh" in script_text
    assert "load_backup_storage_profile velero" in script_text
    assert "hostname -I" not in script_text
    assert "management-ip.sh" not in script_text


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
        backup_profile_dir = bootstrap_root / "secrets/cluster/cluster-test/backup-storage"
        backup_profile_dir.mkdir(parents=True, exist_ok=True)
        (backup_profile_dir / "metadata.json").write_text(
            json.dumps(
                {
                    "mode": "external-s3",
                    "endpoint": "https://s3.example.com",
                    "region": "eu-west-1",
                    "access_key_id": "backup-user",
                    "secret_access_key": "super-secret",
                    "buckets": {"management": "cluster-test-management"},
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

        config_file = (
            bootstrap_root / "secrets/cluster/cluster-test/management-backup/metadata.json"
        )
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
        assert config["endpoint"] == "https://s3.example.com"
        assert config["bucket"] == "cluster-test-management"
        assert config["talosconfig"] == str(cluster_secrets_dir / "talosconfig")
        assert config["host_root"] == str(host_repo_root)
        assert config["retention_days"] == 30
        assert config["exclude_paths"] == []

        assert "17 2 * * * root ${RUNTIME_SCRIPT} etcd" not in cron_text
        assert (
            f"TWINBOX_MANAGEMENT_BACKUP_CONFIG={config_file} {bootstrap_root}/bin/twinbox-management-backup.sh etcd"
            in cron_text
        )
        assert (
            f"TWINBOX_MANAGEMENT_BACKUP_CONFIG={config_file} {bootstrap_root}/bin/twinbox-management-backup.sh opt-twinbox"
            in cron_text
        )

        assert "restic_repo etcd" in runtime_text
        assert "restic_repo opt-twinbox" in runtime_text
        assert 'talosctl etcd snapshot "$snapshot_path"' in runtime_text
        assert '--exclude "${host_root}/seaweedfs/data"' not in runtime_text
