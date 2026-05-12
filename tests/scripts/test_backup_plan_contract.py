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


def test_management_tools_install_restic_for_host_backup_jobs():
    text = (REPO_ROOT / "scripts" / "install-management-tools.sh").read_text(encoding="utf-8")

    assert "install_restic()" in text
    assert "apt-get install -y restic >/dev/null" in text
    assert "command -v restic >/dev/null 2>&1 || fail" in text
    assert "install_restic" in text
