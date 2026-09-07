"""Contract tests for the backup S3 admin reverse-proxy publication."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_admin_script_publishes_backup_s3_domain():
    script = (ROOT / "scripts/manager/configure-seaweedfs-admin.sh").read_text()

    assert "cluster-public-zone.sh" in script
    assert "twinbox_public_zone_name" in script
    assert "https://backup-s3.${public_zone_name}" in script
    assert "https://${ip}:8443" in script
    assert "configure-backup-s3-publication.sh" in script
    assert "BACKUP_S3_PROFILE=" in script


def test_backup_storage_step_provides_kubeconfig_and_slug():
    step = (ROOT / "categories/talos-cluster/steps/configure-backup-storage/step.yaml").read_text()
    runner = (ROOT / "scripts/manager/configure-backup-storage.sh").read_text()

    assert "KUBECONFIG_FILE" in step
    assert "configure-seaweedfs-admin.sh" in runner
    assert "TWINBOX_CLUSTER_SLUG=" in runner


def test_publication_helper_contract():
    helper = (ROOT / "scripts/manager/configure-backup-s3-publication.sh").read_text()

    assert "gitops/apps/backup-s3.yaml" in helper
    assert "gitops/platform-apps/backup-s3" in helper
    assert "__ZONE_NAME__" in helper
    assert "__BACKUP_S3_HOST_IP__" in helper
    assert "apply-argocd-application.sh" in helper
    assert '--application "backup-s3"' in helper
    assert "kubectl apply -f" in helper
    assert 'mode: "forward_single"' in helper
    assert "providers/proxy" in helper
    assert "authentik Embedded Outpost" in helper
    assert "/outposts/instances/" in helper
    assert "authentik_find_group_id" in helper
    assert "ensure-netbird-service.sh" in helper
    assert '--service-name "backup-s3"' in helper
    assert '--service-domain "backup-s3.${public_zone_name}"' in helper
    assert "skipping backup S3 publication" in helper
    assert "managed-seaweedfs" in helper


def test_publication_helper_skips_without_kubeconfig_or_authentik():
    helper = (ROOT / "scripts/manager/configure-backup-s3-publication.sh").read_text()

    assert "command -v kubectl" in helper
    assert "resolve_kubeconfig_file" in helper
    assert "openbao_read_global_secret_json authentik" in helper
    assert "AUTHENTIK_AUTOMATION_TOKEN" in helper
    assert "re-run after the identity stack is ready" in helper
