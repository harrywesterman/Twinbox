"""Contract tests for the optional Twinbox Headwind MDM deployment."""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHART = REPO_ROOT / "gitops" / "platform-apps" / "headwind-mdm"
DATABASE = REPO_ROOT / "gitops" / "databases" / "headwind-mdm"


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_headwind_is_a_real_optional_app_with_status_and_dashy_card():
    step = read("categories/apps/steps/install-headwind-mdm/step.yaml")
    appset = read("gitops/optional-apps/headwind-mdm.yaml")
    apply_script = read("scripts/manager/apply-argocd-application.sh")
    uninstall_script = read("scripts/manager/uninstall-argocd-application.sh")

    assert "id: install-headwind-mdm" in step
    assert "title: Headwind MDM" in step
    assert "url_template: https://mdm-admin.__ZONE_NAME__" in step
    assert 'twinbox.io/app-headwind-mdm: "enabled"' in appset
    assert "path: gitops/platform-apps/headwind-mdm" in appset
    assert "path: gitops/databases/headwind-mdm" in appset
    assert "headwind-mdm" in apply_script
    assert "headwind-mdm" in uninstall_script
    assert "mailu" in uninstall_script
    assert "karakeep" in uninstall_script


def test_headwind_chart_pins_official_runtime_and_persists_all_tomcat_state():
    values = (CHART / "values.yaml").read_text(encoding="utf-8")
    deployment = (CHART / "templates" / "deployment.yaml").read_text(encoding="utf-8")
    pvc = (CHART / "templates" / "pvc.yaml").read_text(encoding="utf-8")

    assert "repository: headwindmdm/hmdm" in values
    assert 'tag: "0.1.8"' in values
    assert "hmdm-5.40.1-os.war" in values
    assert 'launcherVersion: "6.37"' in values
    assert "strategy:" in deployment and "type: Recreate" in deployment
    assert "/usr/local/tomcat/work" in deployment
    assert "/usr/local/tomcat/conf/Catalina/localhost" in deployment
    assert "/usr/local/tomcat/webapps" in deployment
    assert "HMDM_VARIANT" in deployment
    assert "SQL_PASS" in deployment
    assert "SQL_PORT" in deployment
    assert "headwind-mdm-internal-tls" in deployment
    assert "kind: Certificate" in (CHART / "templates" / "internal-tls.yaml").read_text(
        encoding="utf-8"
    )
    assert "storageClassName: {{ .Values.persistence.storageClass }}" in pvc
    assert "ReadWriteOnce" in pvc


def test_bootstrap_gate_changes_initial_admin_before_public_ingress():
    bootstrap = (CHART / "templates" / "bootstrap-job.yaml").read_text(encoding="utf-8")
    ingress = (CHART / "templates" / "ingressroute.yaml").read_text(encoding="utf-8")
    reconciler = (CHART / "files" / "reconcile.mjs").read_text(encoding="utf-8")

    assert "argocd.argoproj.io/hook: Sync" in bootstrap
    assert 'argocd.argoproj.io/sync-wave: "10"' in bootstrap
    assert "ADMIN_PASSWORD" in bootstrap
    assert 'argocd.argoproj.io/sync-wave: "20"' in ingress
    assert "PathPrefix(`/rest/public/`)" in ingress
    assert "PathPrefix(`/files/`)" in ingress
    assert "PathPrefix(`/rest/private/`)" not in ingress
    assert ".Values.ingress.managementHost" in ingress
    assert 'await initialLogin("admin")' in reconciler
    assert "/rest/public/auth/login" in reconciler
    assert "/rest/public/passwordReset/reset" in reconciler
    assert "passwordResetToken" in reconciler
    assert "/rest/public/jwt/login" in reconciler
    assert "authorization: `Bearer ${session.token}`" in reconciler
    assert 'initialLogin("admin")' in reconciler
    assert "/rest/private/users/superadmin/password" not in reconciler
    assert "Twinbox Mobile" in (CHART / "templates" / "catalog-configmap.yaml").read_text(
        encoding="utf-8"
    )
    assert 'pushOptions: "polling"' in reconciler


def test_headwind_uses_openbao_cnpg_backup_and_netbird_management_route():
    runtime_secret = (CHART / "templates" / "externalsecret.yaml").read_text(encoding="utf-8")
    db_secret = (DATABASE / "externalsecret.yaml").read_text(encoding="utf-8")
    cluster = (DATABASE / "cluster.yaml").read_text(encoding="utf-8")
    backup = (DATABASE / "scheduled-backup.yaml").read_text(encoding="utf-8")
    runner = read("categories/apps/steps/install-headwind-mdm/run.sh")

    assert "ClusterSecretStore" in runtime_secret
    assert "HEADWIND_ADMIN_PASSWORD" in runtime_secret
    assert "HEADWIND_DEVICE_ADMIN_PASSWORD" in runtime_secret
    assert "HEADWIND_SHARED_SECRET" in runtime_secret
    assert "HEADWIND_POSTGRESQL__PASSWORD" in db_secret
    assert "kind: Cluster" in cluster
    assert "storageClass: longhorn-single" in cluster
    assert "barmanObjectName: headwind-mdm-db-objectstore" in cluster
    assert "kind: ScheduledBackup" in backup
    assert '--service-name "headwind-mdm"' in runner
    assert '--service-domain "mdm-admin.${public_zone_name}"' in runner
    assert '--service-name "headwind-mdm-enrollment"' in runner
    assert '--service-domain "mdm.${public_zone_name}"' in runner
    assert "HEADWIND_SHARED_SECRET" in runner


def test_mobile_catalog_is_pinned_and_reconciles_only_twinbox_shortcuts():
    catalog = (CHART / "templates" / "catalog-configmap.yaml").read_text(encoding="utf-8")
    reconciler = (CHART / "files" / "reconcile.mjs").read_text(encoding="utf-8")
    trigger = read("scripts/manager/trigger-headwind-mobile-catalog-sync.sh")

    assert '"packageId": "io.netbird.client"' in catalog
    assert '"sha256": "c2f2ef6bc6aece879383e5800090b75f04398464af33c4ba0c1d133243bc32ea"' in catalog
    assert '"signer": "5e60a0abc611aab42b79737a2d2beb9ec712de98e75b82dfceadacda29e93d9f"' in catalog
    assert '"packageId": "org.mozilla.fennec_fdroid"' in catalog
    assert '"signer": "06665358efd8ba05be236a47a12cb0958d7d75dd939d77c2b31f5398537ebdc5"' in catalog
    assert "io.twinbox.mobile.web." in reconciler
    assert "SHA-256 verification failed" in reconciler
    assert 'body?.status === "ERROR"' in reconciler
    assert "async function login(password)" in reconciler
    assert "namespaces/argocd/applications" in reconciler
    assert "create job" in trigger


def test_uninstall_triggers_catalog_sync_only_after_the_application_is_gone():
    uninstall = read("scripts/manager/uninstall-argocd-application.sh")

    assert uninstall.index('kubectl delete application "$APP_NAME"') < uninstall.index(
        "trigger-headwind-mobile-catalog-sync.sh"
    )
