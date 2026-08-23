"""Contract tests for the Euro-Office Nextcloud integration."""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "nextcloud"
OPTIONAL_APP = REPO_ROOT / "gitops" / "optional-apps" / "nextcloud.yaml"
NEXTCLOUD_VALUES = REPO_ROOT / "gitops" / "values" / "nextcloud.yaml"
INSTALL_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-nextcloud" / "run.sh"
EUROOFFICE_ACTION_DIR = (
    REPO_ROOT / "categories" / "apps" / "steps" / "install-nextcloud" / "eurooffice-file-action"
)


def _docs(path):
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]


def _platform_docs():
    docs = []
    for path in PLATFORM_DIR.glob("*.yaml"):
        docs.extend(_docs(path))
    return docs


def _resource(kind, name):
    return next(
        doc
        for doc in _platform_docs()
        if doc.get("kind") == kind and doc.get("metadata", {}).get("name") == name
    )


def test_eurooffice_resources_are_declared_in_the_nextcloud_kustomization():
    kustomization = yaml.safe_load(
        (PLATFORM_DIR / "kustomization.yaml").read_text(encoding="utf-8")
    )

    assert kustomization["resources"] == [
        "namespace.yaml",
        "admin-externalsecret.yaml",
        "db-externalsecret.yaml",
        "eurooffice-externalsecret.yaml",
        "redis-externalsecret.yaml",
        "eurooffice-pvc.yaml",
        "eurooffice-deployment.yaml",
        "eurooffice-service.yaml",
        "eurooffice-forwarded-headers-middleware.yaml",
        "middleware.yaml",
        "ingressroute.yaml",
        "collabora-ingressroute.yaml",
        "eurooffice-ingressroute.yaml",
    ]


def test_eurooffice_secret_uses_the_existing_nextcloud_openbao_secret():
    external_secret = _resource("ExternalSecret", "nextcloud-eurooffice")

    assert external_secret["spec"]["target"]["name"] == "nextcloud-eurooffice"
    assert external_secret["spec"]["data"] == [
        {
            "secretKey": "jwt-secret",
            "remoteRef": {
                "key": "twinbox/global/nextcloud",
                "property": "EUROOFFICE_JWT_SECRET",
            },
        }
    ]


def test_eurooffice_deployment_is_pinned_and_has_health_checks_and_storage():
    deployment = _resource("Deployment", "nextcloud-eurooffice")
    pod_spec = deployment["spec"]["template"]["spec"]
    container = pod_spec["containers"][0]
    env = {item["name"]: item for item in container["env"]}

    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["strategy"] == {"type": "Recreate"}
    assert container["image"] == "ghcr.io/euro-office/documentserver:v9.3.1"
    assert pod_spec["initContainers"][0]["name"] == "initialize-config"
    assert pod_spec["initContainers"][0]["command"] == [
        "/bin/sh",
        "-ec",
        "if [ ! -f /mnt/eurooffice-config/local.json ]; then\n"
        "  cp -a /etc/euro-office/documentserver/. /mnt/eurooffice-config/\n"
        "fi\n"
        "if [ ! -d /mnt/eurooffice-logs/adminpanel ]; then\n"
        "  cp -a /var/log/euro-office/documentserver/. /mnt/eurooffice-logs/\n"
        "fi\n"
        "mkdir -p /mnt/eurooffice-data/App_Data\n"
        "cp -a /var/lib/euro-office/documentserver/App_Data/. /mnt/eurooffice-data/App_Data/\n"
        "chown -R ds:ds /mnt/eurooffice-data\n",
    ]
    assert {item["mountPath"] for item in pod_spec["initContainers"][0]["volumeMounts"]} == {
        "/mnt/eurooffice-config",
        "/mnt/eurooffice-logs",
        "/mnt/eurooffice-data",
    }
    assert env["JWT_ENABLED"]["value"] == "true"
    assert env["JWT_HEADER"]["value"] == "AuthorizationJWT"
    assert env["EXAMPLE_ENABLED"]["value"] == "false"
    assert env["JWT_SECRET"]["valueFrom"]["secretKeyRef"] == {
        "name": "nextcloud-eurooffice",
        "key": "jwt-secret",
    }
    assert container["resources"] == {
        "requests": {"cpu": "100m", "memory": "2Gi"},
        "limits": {"cpu": "2", "memory": "4Gi"},
    }

    for probe_name in ("startupProbe", "readinessProbe", "livenessProbe"):
        assert container[probe_name]["httpGet"] == {
            "path": "/healthcheck",
            "port": "http",
        }

    assert {item["mountPath"] for item in container["volumeMounts"]} == {
        "/var/lib/euro-office/documentserver",
        "/var/log/euro-office/documentserver",
        "/etc/euro-office/documentserver",
    }
    assert {item["name"] for item in pod_spec["volumes"]} == {"data", "logs", "config"}
    assert {volume["persistentVolumeClaim"]["claimName"] for volume in pod_spec["volumes"]} == {
        "nextcloud-eurooffice-data",
        "nextcloud-eurooffice-logs",
        "nextcloud-eurooffice-config",
    }


def test_eurooffice_persistent_volumes_use_longhorn():
    pvcs = [
        doc
        for doc in _platform_docs()
        if doc.get("kind") == "PersistentVolumeClaim"
        and doc.get("metadata", {}).get("name", "").startswith("nextcloud-eurooffice-")
    ]

    assert {pvc["metadata"]["name"] for pvc in pvcs} == {
        "nextcloud-eurooffice-data",
        "nextcloud-eurooffice-logs",
        "nextcloud-eurooffice-config",
    }
    assert all(pvc["spec"]["storageClassName"] == "longhorn" for pvc in pvcs)


def test_eurooffice_routes_are_public_and_netbird_mirrors():
    routes = {
        doc["metadata"]["name"]: doc
        for doc in _platform_docs()
        if doc.get("kind") == "IngressRoute"
        and doc.get("metadata", {}).get("name") in {"eurooffice", "eurooffice-netbird"}
    }

    assert routes["eurooffice"]["spec"]["entryPoints"] == ["websecure"]
    assert routes["eurooffice"]["spec"]["routes"][0] == {
        "kind": "Rule",
        "match": "Host(`nextcloud-eurooffice.__ZONE_NAME__`)",
        "middlewares": [{"name": "eurooffice-forwarded-headers"}],
        "services": [{"name": "nextcloud-eurooffice", "port": 80}],
    }
    assert routes["eurooffice"]["spec"]["tls"] == {}
    assert routes["eurooffice-netbird"]["spec"]["entryPoints"] == ["webnetbird"]
    assert routes["eurooffice-netbird"]["spec"]["routes"] == routes["eurooffice"]["spec"]["routes"]
    assert "tls" not in routes["eurooffice-netbird"]["spec"]


def test_eurooffice_forwarded_headers_middleware_preserves_https_origin():
    middleware = _resource("Middleware", "eurooffice-forwarded-headers")

    assert middleware["spec"] == {
        "headers": {
            "customRequestHeaders": {
                "X-Forwarded-Port": "443",
                "X-Forwarded-Proto": "https",
            }
        }
    }


def test_nextcloud_bootstrap_preserves_collabora_default_and_configures_eurooffice():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")
    optional_app_text = OPTIONAL_APP.read_text(encoding="utf-8")

    assert "init_success=false" in install_text
    assert "php occ maintenance:install" in install_text
    assert "--database=pgsql" in install_text
    assert "EUROOFFICE_JWT_SECRET" in install_text
    assert 'wait_for_deployment_rollout "nextcloud" "nextcloud-eurooffice"' in install_text
    assert "php occ app:install eurooffice" in install_text
    assert "php occ app:enable eurooffice" in install_text
    assert "config:app:set eurooffice DocumentServerUrl" in install_text
    assert "config:app:set eurooffice DocumentServerInternalUrl" in install_text
    assert "config:app:set eurooffice StorageUrl" in install_text
    assert (
        "config:app:set eurooffice jwt_secret --value='${nextcloud_eurooffice_jwt_secret}' "
        "--type=string >/dev/null 2>&1"
    ) in install_text
    assert "config:app:set eurooffice jwt_header --value='AuthorizationJWT'" in install_text
    assert (
        "config:app:set eurooffice sameTab --value='false' --type=string --no-interaction"
        in install_text
    )
    assert (
        "config:app:set eurooffice enableSharing --value='true' --type=string --no-interaction"
        in install_text
    )
    assert (
        "config:app:set eurooffice preview --value='false' --type=string --no-interaction"
        in install_text
    )
    assert (
        "config:app:set --value='https://nextcloud-collabora.${public_zone_name}' richdocuments wopi_url"
        in install_text
    )
    assert '--service-domain "nextcloud-eurooffice.${public_zone_name}"' in install_text
    assert "name: eurooffice" in optional_app_text
    assert "name: eurooffice-netbird" in optional_app_text


def test_nextcloud_installed_status_check_targets_the_app_pod_not_the_cron_pod():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")

    assert install_text.count("app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app") == 2
    assert "get pods -l app.kubernetes.io/name=nextcloud -o jsonpath" not in install_text


def test_nextcloud_bootstrap_installs_the_modern_eurooffice_file_action():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")
    dockerfile_text = (REPO_ROOT / "manager-worker" / "Dockerfile").read_text(encoding="utf-8")
    metadata = EUROOFFICE_ACTION_DIR / "appinfo" / "info.xml"
    application = EUROOFFICE_ACTION_DIR / "lib" / "AppInfo" / "Application.php"
    listener = EUROOFFICE_ACTION_DIR / "lib" / "Listener" / "LoadAdditionalListener.php"
    source = EUROOFFICE_ACTION_DIR / "src" / "main.js"

    assert metadata.exists()
    assert "<id>twinbox_eurooffice_action</id>" in metadata.read_text(encoding="utf-8")
    application_text = application.read_text(encoding="utf-8")
    assert "implements IBootstrap" in application_text
    assert "IRegistrationContext" in application_text
    assert "registerEventListener(" in application_text
    assert "LoadAdditionalScriptsEvent::class" in application_text
    listener_text = listener.read_text(encoding="utf-8")
    assert "LoadAdditionalScriptsEvent" in listener_text
    assert "use OCP\\EventDispatcher\\IEventListener;" in listener_text
    assert "class LoadAdditionalListener implements IEventListener" in listener_text
    assert (
        "Util::addScript(Application::APP_ID, 'twinbox_eurooffice_action-main', 'files')"
        in listener_text
    )
    source_text = source.read_text(encoding="utf-8")
    assert "registerFileAction" in source_text
    assert "id: 'twinbox-eurooffice-open'" in source_text
    assert "Open in EuroOffice" in source_text
    assert "npm ci" in dockerfile_text
    assert "eurooffice-file-action" in dockerfile_text
    assert "/var/www/html/custom_apps" in install_text
    assert "php occ app:enable twinbox_eurooffice_action" in install_text


def test_twinbox_companion_keeps_collabora_as_the_default_direct_editor():
    application = EUROOFFICE_ACTION_DIR / "lib" / "AppInfo" / "Application.php"
    listener = EUROOFFICE_ACTION_DIR / "lib" / "Listener" / "CollaboraDefaultListener.php"
    adapter = EUROOFFICE_ACTION_DIR / "lib" / "DirectEditing" / "EuroOfficeDirectEditor.php"

    application_text = application.read_text(encoding="utf-8")
    assert "RegisterDirectEditorEvent::class" in application_text
    assert "CollaboraDefaultListener::class" in application_text
    assert listener.exists()
    listener_text = listener.read_text(encoding="utf-8")
    assert "getEditors()" in listener_text
    assert "new EuroOfficeDirectEditor($editors['richdocuments'])" in listener_text
    assert adapter.exists()
    assert "implements IEditor" in adapter.read_text(encoding="utf-8")
    assert "return 'eurooffice';" in adapter.read_text(encoding="utf-8")


def test_collabora_is_privileged_for_document_jail_mounts():
    values = yaml.safe_load(NEXTCLOUD_VALUES.read_text(encoding="utf-8"))
    optional_app_text = OPTIONAL_APP.read_text(encoding="utf-8")
    namespace = _resource("Namespace", "nextcloud")

    assert values["collabora"]["securityContext"] == {"privileged": True}
    assert "securityContext" not in values["collabora"]["collabora"]
    assert "securityContext:\n                  privileged: true" in optional_app_text
    assert namespace["metadata"]["labels"] == {
        "pod-security.kubernetes.io/enforce": "privileged",
        "pod-security.kubernetes.io/audit": "privileged",
        "pod-security.kubernetes.io/warn": "privileged",
    }
