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
MAIL_PROVISIONING_DIR = (
    REPO_ROOT / "categories" / "apps" / "steps" / "install-nextcloud" / "twinbox-mail-provisioning"
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
        "mailu-runtime-externalsecret.yaml",
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
        "signaling-externalsecret.yaml",
        "signaling-deployment.yaml",
        "signaling-service.yaml",
        "signaling-ingressroute.yaml",
        "coturn-externalsecret.yaml",
        "coturn-configmap.yaml",
        "coturn-deployment.yaml",
        "coturn-service.yaml",
        "coturn-turn-certificate.yaml",
        "coturn-turn-ingressroutetcp.yaml",
        "nats-deployment.yaml",
        "nats-service.yaml",
        "recording-externalsecret.yaml",
        "recording-deployment.yaml",
        "recording-service.yaml",
        "recording-pvc.yaml",
        "recording-ingressroute.yaml",
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


def test_nextcloud_bootstrap_installs_talk_under_its_spreed_app_id():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")

    assert "php occ app:install spreed >/dev/null 2>&1 || true" in install_text
    assert "php occ app:enable spreed >/dev/null 2>&1 || true" in install_text
    assert "app:install talk" not in install_text
    assert "app:enable talk" not in install_text


def test_nextcloud_hpb_signaling_server_is_deployed_and_routed():
    deployment = _resource("Deployment", "nextcloud-signaling")
    service = _resource("Service", "nextcloud-signaling")
    external_secret = _resource("ExternalSecret", "nextcloud-signaling-config")
    routes = {
        doc["metadata"]["name"]: doc
        for doc in _platform_docs()
        if doc.get("kind") == "IngressRoute"
        and doc.get("metadata", {}).get("name") in {"signaling", "signaling-netbird"}
    }

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {item["name"]: item for item in container["env"]}
    assert container["image"] == "strukturag/nextcloud-spreed-signaling:2.1.1"
    assert env["HTTP_LISTEN"]["value"] == "0.0.0.0:8080"
    assert env["BACKENDS"]["value"] == "backend1"
    assert env["BACKEND_BACKEND1_URLS"]["value"] == "https://nextcloud.__ZONE_NAME__"
    assert env["BACKEND_BACKEND1_SHARED_SECRET"]["valueFrom"]["secretKeyRef"] == {
        "name": "nextcloud-signaling-config",
        "key": "signaling-secret",
    }
    assert env["INTERNAL_SHARED_SECRET_KEY"]["valueFrom"]["secretKeyRef"]["key"] == (
        "internal-secret"
    )
    assert env["NATS_URL"]["value"] == "nats://nextcloud-nats.nextcloud.svc.cluster.local:4222"

    assert service["spec"]["ports"] == [{"name": "http", "port": 8080, "targetPort": 8080}]
    assert external_secret["spec"]["target"]["name"] == "nextcloud-signaling-config"
    assert routes["signaling"]["spec"]["entryPoints"] == ["websecure"]
    assert routes["signaling-netbird"]["spec"]["entryPoints"] == ["webnetbird"]
    assert routes["signaling"]["spec"]["routes"][0] == {
        "kind": "Rule",
        "match": "Host(`signaling.__ZONE_NAME__`)",
        "services": [{"kind": "Service", "name": "nextcloud-signaling", "port": 8080}],
    }


def test_nextcloud_hpb_coturn_serves_turn_tls_on_443_with_dedicated_cert():
    deployment = _resource("Deployment", "nextcloud-coturn")
    service = _resource("Service", "nextcloud-coturn")
    certificate = _resource("Certificate", "nextcloud-talk-turn-tls")
    route = _resource("IngressRouteTCP", "nextcloud-talk-turn")

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {item["name"]: item for item in container["env"]}
    assert container["image"] == "coturn/coturn:4.17.2"
    assert '--static-auth-secret="${TURN_STATIC_AUTH_SECRET}"' in " ".join(container["command"])
    assert env["TURN_STATIC_AUTH_SECRET"]["valueFrom"]["secretKeyRef"] == {
        "name": "nextcloud-turn-config",
        "key": "static-auth-secret",
    }
    assert {volume["name"] for volume in deployment["spec"]["template"]["spec"]["volumes"]} == {
        "config",
        "tls",
    }

    assert service["spec"]["ports"] == [
        {"name": "turns", "port": 443, "targetPort": 443},
        {"name": "turn-tcp", "port": 3478, "targetPort": 3478},
        {"name": "turn-udp", "port": 3478, "targetPort": 3478, "protocol": "UDP"},
    ]
    assert certificate["spec"]["dnsNames"] == ["talk-turn.__ZONE_NAME__"]
    assert route["spec"]["routes"] == [
        {
            "match": "HostSNI(`talk-turn.__ZONE_NAME__`)",
            "priority": 10,
            "services": [{"name": "nextcloud-coturn", "port": 443}],
        }
    ]
    assert route["spec"]["tls"] == {"passthrough": True}
    assert route["spec"]["entryPoints"] == ["websecure"]


def test_nextcloud_hpb_recording_backend_is_deployed_and_routed():
    deployment = _resource("Deployment", "nextcloud-recording")
    service = _resource("Service", "nextcloud-recording")
    pvc = _resource("PersistentVolumeClaim", "nextcloud-recording")
    external_secret = _resource("ExternalSecret", "nextcloud-recording-config")
    routes = {
        doc["metadata"]["name"]: doc
        for doc in _platform_docs()
        if doc.get("kind") == "IngressRoute"
        and doc.get("metadata", {}).get("name") in {"recording", "recording-netbird"}
    }

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {item["name"]: item for item in container["env"]}
    assert container["image"] == "ghcr.io/nextcloud-releases/aio-talk-recording:20260825_084538"
    assert env["NC_DOMAIN"]["value"] == "nextcloud.__ZONE_NAME__"
    assert env["HPB_DOMAIN"]["value"] == "signaling.__ZONE_NAME__"
    assert env["HPB_PROTOCOL"]["value"] == "https"
    assert env["RECORDING_SECRET"]["valueFrom"]["secretKeyRef"] == {
        "name": "nextcloud-recording-config",
        "key": "recording-secret",
    }
    assert env["INTERNAL_SECRET"]["valueFrom"]["secretKeyRef"]["key"] == "internal-secret"
    assert pvc["spec"]["storageClassName"] == "longhorn"

    assert service["spec"]["ports"] == [{"name": "http", "port": 1234, "targetPort": 1234}]
    assert external_secret["spec"]["target"]["name"] == "nextcloud-recording-config"
    assert routes["recording"]["spec"]["routes"][0] == {
        "kind": "Rule",
        "match": "Host(`recording.__ZONE_NAME__`)",
        "services": [{"kind": "Service", "name": "nextcloud-recording", "port": 1234}],
    }


def test_nextcloud_hpb_secrets_come_from_openbao_talk_runtime():
    for name in (
        "nextcloud-signaling-config",
        "nextcloud-turn-config",
        "nextcloud-recording-config",
    ):
        external_secret = _resource("ExternalSecret", name)
        assert external_secret["spec"]["secretStoreRef"] == {
            "name": "openbao",
            "kind": "ClusterSecretStore",
        }
        assert all(
            entry["remoteRef"]["key"] == "twinbox/global/nextcloud-talk-runtime"
            for entry in external_secret["spec"]["data"]
        )

    signaling = _resource("ExternalSecret", "nextcloud-signaling-config")
    assert {entry["secretKey"] for entry in signaling["spec"]["data"]} == {
        "signaling-secret",
        "internal-secret",
        "session-hash-key",
        "session-block-key",
    }
    turn = _resource("ExternalSecret", "nextcloud-turn-config")
    assert turn["spec"]["data"] == [
        {
            "secretKey": "static-auth-secret",
            "remoteRef": {
                "key": "twinbox/global/nextcloud-talk-runtime",
                "property": "TALK_TURN_SECRET",
            },
        }
    ]


def test_nextcloud_hpb_bootstrap_provisions_secrets_configures_talk_and_netbird():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")
    optional_app_text = OPTIONAL_APP.read_text(encoding="utf-8")

    assert "Provisioning Nextcloud Talk HPB runtime secrets" in install_text
    assert "nextcloud-talk-runtime" in install_text
    assert (
        '--required-keys "TALK_SIGNALING_SECRET,TALK_INTERNAL_SECRET,TALK_SESSION_HASHKEY,TALK_SESSION_BLOCKKEY,TALK_TURN_SECRET,TALK_RECORDING_SECRET"'
        in install_text
    )
    assert (
        "talk:signaling:add --verify https://signaling.${public_zone_name}/ ${talk_signaling_secret}"
        in install_text
    )
    assert (
        "talk:turn:add turns talk-turn.${public_zone_name} tcp --secret ${talk_turn_secret}"
        in install_text
    )
    assert "talk:stun:add talk-turn.${public_zone_name}:3478" in install_text
    assert "stun_servers --value='[\\\"talk-turn.${public_zone_name}:3478\\\"]'" in install_text
    assert "recording_servers" in install_text
    assert '--service-name "nextcloud-signaling"' in install_text
    assert '--service-name "nextcloud-talk-turn"' in install_text
    assert '--service-mode "tls"' in install_text

    assert "name: signaling" in optional_app_text
    assert "name: signaling-netbird" in optional_app_text
    assert "name: recording" in optional_app_text
    assert "name: nextcloud-talk-turn" in optional_app_text
    assert "value: Host(`signaling.{{index .metadata.annotations" in optional_app_text
    assert "value: HostSNI(`talk-turn.{{index .metadata.annotations" in optional_app_text
    assert "path: /spec/template/spec/containers/0/env/2/value" in optional_app_text


def test_nextcloud_installed_status_check_targets_the_app_pod_not_the_cron_pod():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")

    assert (
        install_text.count("app.kubernetes.io/name=nextcloud,app.kubernetes.io/component=app") >= 2
    )
    assert "get pods -l app.kubernetes.io/name=nextcloud -o jsonpath" not in install_text


def test_nextcloud_bootstrap_allowlists_cluster_pod_cidrs_in_bruteforce_protection():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")

    assert "Allowlisting cluster pod CIDRs in Nextcloud brute-force protection" in install_text
    assert "config:app:set bruteForce whitelist_" in install_text
    assert "kubectl get nodes -o json" in install_text
    assert "spec.podCIDRs" in install_text
    assert "spec.podCIDR" in install_text
    assert "brute-force allowlist not configured" in install_text
    assert "10.244.0.0/16" not in install_text


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


def test_nextcloud_mail_uses_per_user_mailu_tokens():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")
    values = yaml.safe_load(NEXTCLOUD_VALUES.read_text(encoding="utf-8"))

    assert "command -v python3" in install_text
    assert 'configure_nextcloud_mail_accounts "$public_zone_name"' in install_text
    assert "Skipping Nextcloud Mail account sync because Mailu is not installed yet" in install_text
    assert 'fail "Nextcloud Mail account sync failed for ${failed} user(s)"' in install_text
    assert "mailu_create_auth_token" in install_text
    assert "MAILU_API_TOKEN" in install_text
    assert 'env MAILU_API_TOKEN="$api_token"' in install_text
    assert "kubectl exec -i -n mailu deploy/mailu-admin -c admin" in install_text
    assert "Authorization: Bearer ${MAILU_API_TOKEN}" in install_text
    assert "Authorization: Bearer ${API_TOKEN}" not in install_text
    assert "/tokenuser/" in install_text
    assert "Nextcloud Mail" in install_text
    assert "nextcloud_user_id_for_mail_account" in install_text
    assert "user:list --output=json" in install_text
    assert "user:info $(printf '%q' \"$candidate\") --output=json" in install_text
    assert "Nextcloud user with this email does not exist yet" in install_text
    assert "php occ mail:account:create" in install_text
    assert "mail:account:create $(printf '%q' \"$nextcloud_user_id\")" in install_text
    assert 'imap_hostname="mailu-dovecot.mailu.svc.cluster.local"' in install_text
    assert 'imap_port="143"' in install_text
    assert 'imap_security="none"' in install_text
    assert 'smtp_hostname="mailu-front.mailu.svc.cluster.local"' in install_text
    assert 'smtp_port="10025"' in install_text
    assert 'smtp_security="tls"' in install_text
    assert "mail.${mail_domain}" not in install_text
    assert " 993 ssl " not in install_text
    assert " 587 tls " not in install_text
    assert "mail:account:export" in install_text
    assert "masterPassword" not in install_text
    assert (
        "'app.mail.verify-tls-peer' => false" in values["nextcloud"]["configs"]["mail.config.php"]
    )


def test_nextcloud_mail_provisioning_app_is_installed_and_listens_for_login():
    install_text = INSTALL_STEP.read_text(encoding="utf-8")
    metadata = MAIL_PROVISIONING_DIR / "appinfo" / "info.xml"
    application = MAIL_PROVISIONING_DIR / "lib" / "AppInfo" / "Application.php"
    listener = MAIL_PROVISIONING_DIR / "lib" / "Listener" / "UserLoggedInListener.php"
    job = MAIL_PROVISIONING_DIR / "lib" / "BackgroundJob" / "ProvisionMailAccountJob.php"
    provisioner = MAIL_PROVISIONING_DIR / "lib" / "Service" / "MailAccountProvisioner.php"
    mailu_client = MAIL_PROVISIONING_DIR / "lib" / "Service" / "MailuClient.php"

    assert metadata.exists()
    assert "<id>twinbox_mail_provisioning</id>" in metadata.read_text(encoding="utf-8")
    application_text = application.read_text(encoding="utf-8")
    assert "UserLoggedInEvent::class" in application_text
    assert "UserLoggedInListener::class" in application_text

    listener_text = listener.read_text(encoding="utf-8")
    assert "class UserLoggedInListener implements IEventListener" in listener_text
    assert "IJobList" in listener_text
    assert "MailAccountProvisioner" in listener_text
    assert "Immediate Twinbox Mail provisioning failed; queued retry" in listener_text
    assert "ProvisionMailAccountJob::class" in listener_text
    assert "TWINBOX_MAIL_DOMAIN" in listener_text
    assert "getBackendClassName()" not in listener_text
    assert "user_oidc" not in listener_text
    assert "$user->getUID() === 'admin'" in listener_text

    job_text = job.read_text(encoding="utf-8")
    assert "extends QueuedJob" in job_text
    assert "parent::__construct($time)" in job_text
    assert "MailAccountProvisioner" in job_text
    assert "'exception' => $error" in job_text

    provisioner_text = provisioner.read_text(encoding="utf-8")
    assert "mail:account:export" in provisioner_text
    assert "mail:account:create" in provisioner_text
    assert "mailu-dovecot.mailu.svc.cluster.local" in provisioner_text
    assert "mailu-front.mailu.svc.cluster.local" in provisioner_text
    assert "10025" in provisioner_text
    assert "'tls'" in provisioner_text
    assert "993" not in provisioner_text
    assert "587" not in provisioner_text

    mailu_client_text = mailu_client.read_text(encoding="utf-8")
    assert "TWINBOX_MAILU_API_BASE" in mailu_client_text
    assert "TWINBOX_MAILU_API_TOKEN" in mailu_client_text
    assert "/tokenuser/" in mailu_client_text
    assert "Nextcloud Mail" in mailu_client_text

    assert "twinbox-mail-provisioning" in install_text
    assert "twinbox_mail_provisioning" in install_text
    assert "php occ app:enable twinbox_mail_provisioning" in install_text


def test_nextcloud_mail_provisioning_app_has_mailu_secret_wiring():
    kustomization = yaml.safe_load(
        (PLATFORM_DIR / "kustomization.yaml").read_text(encoding="utf-8")
    )
    external_secret = _resource("ExternalSecret", "nextcloud-mailu-runtime")
    values = yaml.safe_load(NEXTCLOUD_VALUES.read_text(encoding="utf-8"))
    optional_text = OPTIONAL_APP.read_text(encoding="utf-8")

    assert "mailu-runtime-externalsecret.yaml" in kustomization["resources"]
    assert external_secret["spec"]["target"]["name"] == "nextcloud-mailu-runtime"
    assert external_secret["spec"]["data"] == [
        {
            "secretKey": "api-token",
            "remoteRef": {
                "key": "twinbox/global/mailu-runtime",
                "property": "api-token",
            },
        }
    ]

    nextcloud_env = {entry["name"]: entry for entry in values["nextcloud"]["extraEnv"]}
    assert "env" not in values["nextcloud"]
    assert "env" not in values["cronjob"]["cronjob"]
    assert nextcloud_env["TWINBOX_MAIL_DOMAIN"]["value"] == "__ZONE_NAME__"
    assert (
        nextcloud_env["TWINBOX_MAILU_API_BASE"]["value"]
        == "http://mailu-front.mailu.svc.cluster.local/api/v1"
    )
    assert nextcloud_env["TWINBOX_MAILU_API_TOKEN"]["valueFrom"]["secretKeyRef"] == {
        "name": "nextcloud-mailu-runtime",
        "key": "api-token",
        "optional": True,
    }

    assert "extraEnv:" in optional_text
    assert "- name: TWINBOX_MAIL_DOMAIN" in optional_text
    assert "value: '{{index .metadata.annotations" in optional_text
    assert "- name: TWINBOX_MAILU_API_TOKEN" in optional_text
    assert "name: nextcloud-mailu-runtime" in optional_text


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
