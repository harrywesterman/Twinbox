from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SYNC_SCRIPT = REPO_ROOT / "scripts" / "manager" / "sync-openbao-global-secret.sh"
OPENBAO_HELPER = REPO_ROOT / "scripts" / "manager" / "openbao-secret-sync.sh"
UPGRADE_SCRIPT = REPO_ROOT / "scripts" / "manager" / "upgrade-cluster.sh"
GRAFANA_STEP = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh"
WIREDOOR_STEP = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-wiredoor-gateway" / "run.sh"
)
GRAFANA_SECRET = REPO_ROOT / "gitops" / "platform" / "grafana" / "externalsecret.yaml"
WIREDOOR_SECRET = REPO_ROOT / "gitops" / "apps" / "wiredoor-gateway-secret" / "externalsecret.yaml"
TRAEFIK_SECRET = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "traefik-dashboard-externalsecret.yaml"
)
CROWDSEC_BOUNCER_SECRET = (
    REPO_ROOT / "gitops" / "platform" / "crowdsec" / "bouncer-externalsecret.yaml"
)
CROWDSEC_LAPI_SECRET = REPO_ROOT / "gitops" / "platform" / "crowdsec" / "lapi-externalsecret.yaml"
TRAEFIK_CROWDSEC_BOUNCER_SECRET = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "crowdsec-bouncer-externalsecret.yaml"
)
PORTAL_SECRET = REPO_ROOT / "gitops" / "platform-apps" / "twinbox-portal" / "externalsecret.yaml"
PORTAL_STEP = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-twinbox-portal" / "run.sh"
)
TALOS_CATEGORY = REPO_ROOT / "categories" / "talos-cluster" / "category.yaml"
PIXELFED_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-pixelfed" / "run.sh"
ZULIP_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-zulip" / "step.yaml"
ZULIP_RUN = REPO_ROOT / "categories" / "apps" / "steps" / "install-zulip" / "run.sh"
ZULIP_APP = REPO_ROOT / "gitops" / "apps" / "zulip.yaml"
ZULIP_PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "zulip"
ZULIP_RUNTIME_SECRET = ZULIP_PLATFORM_DIR / "runtime-externalsecret.yaml"
ZULIP_VALUES = REPO_ROOT / "gitops" / "values" / "zulip.yaml"
ZULIP_DB_CLUSTER = REPO_ROOT / "gitops" / "databases" / "zulip" / "cluster.yaml"
PIXELFED_SECRET = REPO_ROOT / "gitops" / "platform-apps" / "pixelfed" / "externalsecret.yaml"
PIXELFED_DB_CLUSTER = REPO_ROOT / "gitops" / "databases" / "pixelfed" / "cluster.yaml"
OUTLINE_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-outline" / "run.sh"
OUTLINE_APP = REPO_ROOT / "gitops" / "apps" / "outline.yaml"
OUTLINE_PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "outline"
OUTLINE_DEPLOYMENT = OUTLINE_PLATFORM_DIR / "deployment.yaml"
OUTLINE_SECRET = OUTLINE_PLATFORM_DIR / "externalsecret.yaml"
OUTLINE_DB_CLUSTER = REPO_ROOT / "gitops" / "databases" / "outline" / "cluster.yaml"
REMOVED_PLACEHOLDER_STEP = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-vaultwarden-app" / "step.yaml"
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_sync_openbao_global_secret_script_uses_port_forward_and_kv_v2_api():
    text = _read(SYNC_SCRIPT)

    assert "set -euo pipefail" in text
    assert "--secret-name NAME --json-file PATH" in text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in text
    assert (
        'openbao_sync_global_secret_file "$SECRET_NAME" "$JSON_FILE" "${required_key_list[@]}"'
        in text
    )


def test_openbao_global_secret_reads_use_active_service_port_forward():
    text = _read(OPENBAO_HELPER)
    read_function = text.split("openbao_read_global_secret_json() {", 1)[1].split(
        "openbao_read_global_secret_field() {", 1
    )[0]

    assert 'kubectl -n "$OPENBAO_NAMESPACE" port-forward "svc/openbao-active"' in read_function
    assert "/v1/kv/data/twinbox/global/${secret_name}" in read_function
    assert "openbao_wait_for_server_pod" not in read_function
    assert "bao kv get" not in read_function


def test_openbao_kubernetes_auth_uses_external_secrets_client_jwt_reviewer():
    text = _read(OPENBAO_HELPER)
    configure_function = text.split("openbao_configure_auth_and_policy() {", 1)[1].split(
        "openbao_seed_secret_paths() {", 1
    )[0]

    assert "token_reviewer_jwt" not in configure_function
    assert "disable_local_ca_jwt=true" in configure_function
    assert "bound_service_account_names=external-secrets" in configure_function
    assert "bound_service_account_namespaces=external-secrets" in configure_function


def test_openbao_repair_grants_external_secrets_tokenreview_and_validates_store():
    text = _read(OPENBAO_HELPER)

    assert "name: external-secrets-tokenreview" in text
    assert "name: system:auth-delegator" in text
    assert "kind: ClusterSecretStore" in text
    assert "openbao_force_cluster_secret_store_refresh" in text
    assert "openbao_wait_for_cluster_secret_store_ready" in text
    assert "OpenBao Kubernetes auth is not ready" in text


def test_upgrade_completion_runs_openbao_auth_gate_before_marking_completed():
    text = _read(UPGRADE_SCRIPT)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in text
    assert "openbao_secret_sync_health_gate" in text
    assert text.index("openbao_secret_sync_health_gate") < text.index('status = "talos_completed"')
    assert text.rindex("openbao_secret_sync_health_gate") < text.index(
        'status = "kubernetes_completed"'
    )
    assert "authentik-bootstrap" in text
    assert "authentik-db-credentials" in text


def test_grafana_step_generates_and_syncs_an_oidc_secret():
    text = _read(GRAFANA_STEP)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in text
    assert (
        'grafana_secret_file="$BOOTSTRAP_ROOT/secrets/global/grafana-oidc-${cluster_id}.json"'
        in text
    )
    assert "openssl rand -hex 16" in text
    assert "openssl rand -hex 24" in text
    assert "Provisioning Authentik OIDC client for Grafana" in text
    assert '"GF_AUTH_GENERIC_OAUTH_CLIENT_ID": $oauth_client_id' in text
    assert '"GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": $oauth_client_secret' in text
    assert '"GF_SECURITY_ADMIN_USER": $admin_user' in text
    assert '"GF_SECURITY_ADMIN_PASSWORD": $admin_password' in text
    assert "scripts/manager/sync-openbao-global-secret.sh" in text
    assert '--secret-name "grafana-oidc"' in text
    assert (
        '--required-keys "GF_AUTH_DISABLE_LOGIN_FORM,GF_AUTH_OAUTH_AUTO_LOGIN,GF_AUTH_BASIC_ENABLED,GF_USERS_AUTO_ASSIGN_ORG_ROLE,GF_AUTH_GENERIC_OAUTH_ENABLED,GF_AUTH_GENERIC_OAUTH_NAME,GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP,GF_AUTH_GENERIC_OAUTH_CLIENT_ID,GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET,GF_AUTH_GENERIC_OAUTH_SCOPES,GF_AUTH_GENERIC_OAUTH_AUTH_URL,GF_AUTH_GENERIC_OAUTH_TOKEN_URL,GF_AUTH_GENERIC_OAUTH_API_URL,GF_SECURITY_ADMIN_USER,GF_SECURITY_ADMIN_PASSWORD"'
        in text
    )
    assert (
        "kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-oidc --timeout=10m"
        in text
    )


def test_wiredoor_step_requires_url_generates_token_and_syncs_to_openbao():
    text = _read(WIREDOOR_STEP)

    assert 'mkdir -p "$(dirname "$wiredoor_secret_file")"' in text
    assert 'if [[ ! -f "$wiredoor_secret_file" ]]; then' in text
    assert 'wiredoor_url="${WIREDOOR_URL:-${TWINBOX_WIREDOOR_URL:-}}"' in text
    assert "openssl rand -hex 24" in text
    assert 'wiredoor_secret_file="$BOOTSTRAP_ROOT/secrets/global/wiredoor-gateway.json"' in text
    assert "WIREDOOR_URL missing in $wiredoor_secret_file" in text
    assert "scripts/manager/sync-openbao-global-secret.sh" in text
    assert '--secret-name "wiredoor-gateway"' in text
    assert '--required-keys "WIREDOOR_URL,TOKEN"' in text


def test_portal_step_and_secret_project_authentik_management_env():
    step_text = _read(PORTAL_STEP)
    secret_text = _read(PORTAL_SECRET)

    assert '"AUTHENTIK_API_BASE": "$authentik_api_base"' in step_text
    assert 'grant_types: ["authorization_code"]' in step_text
    assert (
        '--required-keys "PORTAL_BASE_URL,PORTAL_OIDC_CLIENT_ID,PORTAL_OIDC_ISSUER,PORTAL_SESSION_SECRET,AUTHENTIK_API_BASE"'
        in step_text
    )

    assert "name: portal-bootstrap" in secret_text
    assert "secretKey: AUTHENTIK_API_BASE" in secret_text
    assert "property: AUTHENTIK_API_BASE" in secret_text
    assert "secretKey: AUTHENTIK_API_TOKEN" in secret_text
    assert "key: twinbox/global/authentik" in secret_text
    assert "property: AUTHENTIK_API_TOKEN" in secret_text


def test_gitops_secret_consumers_now_reference_cluster_secret_store_openbao():
    grafana_text = _read(GRAFANA_SECRET)
    wiredoor_text = _read(WIREDOOR_SECRET)
    traefik_text = _read(TRAEFIK_SECRET)
    crowdsec_bouncer_text = _read(CROWDSEC_BOUNCER_SECRET)
    crowdsec_lapi_text = _read(CROWDSEC_LAPI_SECRET)
    traefik_crowdsec_bouncer_text = _read(TRAEFIK_CROWDSEC_BOUNCER_SECRET)

    assert "name: openbao" in grafana_text
    assert "kind: ClusterSecretStore" in grafana_text
    assert "name: grafana-oidc" in grafana_text
    assert "property: GF_AUTH_GENERIC_OAUTH_CLIENT_ID" in grafana_text
    assert "property: GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET" in grafana_text
    assert "property: GF_SECURITY_ADMIN_USER" in grafana_text
    assert "property: GF_SECURITY_ADMIN_PASSWORD" in grafana_text

    assert "name: openbao" in wiredoor_text
    assert "kind: ClusterSecretStore" in wiredoor_text
    assert "property: WIREDOOR_URL" in wiredoor_text
    assert "property: TOKEN" in wiredoor_text

    assert "name: openbao" in traefik_text
    assert "kind: ClusterSecretStore" in traefik_text
    assert "property: users" in traefik_text

    assert "name: openbao" in crowdsec_bouncer_text
    assert "kind: ClusterSecretStore" in crowdsec_bouncer_text
    assert "secretKey: BOUNCER_KEY_traefik" in crowdsec_bouncer_text
    assert "key: twinbox/global/crowdsec-bouncer" in crowdsec_bouncer_text
    assert "property: lapi_key" in crowdsec_bouncer_text

    assert "kind: ExternalSecret" in crowdsec_lapi_text
    assert "name: openbao" in crowdsec_lapi_text
    assert "secretKey: csLapiSecret" in crowdsec_lapi_text
    assert "secretKey: registrationToken" in crowdsec_lapi_text
    assert "key: twinbox/global/crowdsec-lapi" in crowdsec_lapi_text
    assert "property: csLapiSecret" in crowdsec_lapi_text
    assert "property: registrationToken" in crowdsec_lapi_text

    assert "name: openbao" in traefik_crowdsec_bouncer_text
    assert "kind: ClusterSecretStore" in traefik_crowdsec_bouncer_text
    assert "secretKey: lapi-key" in traefik_crowdsec_bouncer_text
    assert "key: twinbox/global/crowdsec-bouncer" in traefik_crowdsec_bouncer_text
    assert "property: lapi_key" in traefik_crowdsec_bouncer_text


def test_removed_placeholder_step_is_absent_from_the_journey():
    assert not REMOVED_PLACEHOLDER_STEP.exists()


def test_zulip_step_is_backed_by_a_real_runner_and_gitops_resources():
    step_text = _read(ZULIP_STEP)
    run_text = _read(ZULIP_RUN)
    app_text = _read(ZULIP_APP)
    values_text = _read(ZULIP_VALUES)
    runtime_secret_text = _read(ZULIP_RUNTIME_SECRET)
    db_cluster_text = _read(ZULIP_DB_CLUSTER)

    assert "Placeholder step" not in step_text
    assert "categories/apps/steps/install-zulip/run.sh" in step_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in run_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in run_text
    assert 'mkdir -p "$secrets_dir"' in run_text
    assert "zulip_runtime_secret_file=" in run_text
    assert "openbao_read_global_secret_json zulip-runtime" in run_text
    assert "sync-openbao-global-secret.sh" in run_text
    assert '--secret-name "zulip-runtime"' in run_text
    assert (
        '--required-keys "ZULIP_RABBITMQ_PASSWORD,ZULIP_RABBITMQ_ERLANG_COOKIE,ZULIP_REDIS_PASSWORD"'
        in run_text
    )
    assert "zulip_config_secret_json" in run_text
    assert "zulip_runtime_secret_json" in run_text
    assert "LOADBALANCER_IPS" not in run_text
    assert "__ZULIP_RABBITMQ_PASSWORD__" not in run_text
    assert "__ZULIP_REDIS_PASSWORD__" not in run_text

    assert "kind: ApplicationSet" in app_text
    assert "name: zulip-set" in app_text
    assert "repoURL: oci://ghcr.io/zulip/helm-charts/zulip" in app_text
    assert "path: ." in app_text
    assert 'targetRevision: "2.0.0"' in app_text
    assert "path: gitops/platform-apps/zulip" in app_text
    assert (
        'SETTING_EXTERNAL_HOST: zulip.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in app_text
    )
    assert (
        'SETTING_ZULIP_ADMINISTRATOR: admin@{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in app_text
    )
    assert "ZULIP_AUTH_BACKENDS: GenericOpenIdConnectBackend" in app_text
    assert 'TRUST_GATEWAY_IP: "True"' in app_text
    assert "ZULIP_DEFAULT_REALM_OWNER_EMAIL:" not in app_text
    assert "ZULIP_DEFAULT_REALM_OWNER_NAME:" not in app_text
    assert "existingPasswordSecret: zulip-runtime" in app_text
    assert "existingSecretPasswordKey: rabbitmq-password" in app_text
    assert "existingErlangSecret: zulip-runtime" in app_text
    assert "existingSecretErlangKey: rabbitmq-erlang-cookie" in app_text
    assert "existingSecret: zulip-runtime" in app_text
    assert "existingSecretPasswordKey: redis-password" in app_text
    assert "LOADBALANCER_IPS:" in app_text
    assert "pod-cidr" in app_text
    assert "__ZULIP_RABBITMQ_PASSWORD__" not in app_text
    assert "__ZULIP_REDIS_PASSWORD__" not in app_text

    assert "size: 10Gi" in values_text
    assert "postgresql:" in values_text
    assert "enabled: false" in values_text
    assert "externalPostgresql:" in values_text
    assert "host: zulip-db-pooler-rw.databases.svc.cluster.local" in values_text
    assert "name: zulip-db-credentials" in values_text
    assert "key: password" in values_text
    assert "storageClass: longhorn" in values_text
    assert "SECRETS_secret_key:" in values_text
    assert "SETTING_SOCIAL_AUTH_OIDC_ENABLED_IDPS:" in values_text
    assert "ZULIP_DEFAULT_REALM_OWNER_EMAIL:" in values_text
    assert "ZULIP_DEFAULT_REALM_OWNER_NAME:" in values_text
    assert "persistence:" in values_text
    assert "postSetup:" in values_text
    assert "10-create-default-realm.sh" in values_text
    assert "create-users-and-groups.json" in run_text
    assert "MANAGER_DATA_DIR" in run_text
    assert "announcements" in values_text
    assert "support" in values_text
    assert (
        'desired_jitsi_server_url = "https://${SETTING_EXTERNAL_HOST/zulip./jitsi.}"' in values_text
    )
    assert (
        'desired_video_chat_provider = Realm.VIDEO_CHAT_PROVIDERS["jitsi_meet"]["id"]'
        in values_text
    )
    assert "send_initial_realm_messages(realm)" in values_text
    assert "Realm.objects.filter(string_id=" in values_text
    assert "realm.jitsi_server_url" in values_text
    assert "realm.video_chat_provider" in values_text
    assert "cat > /tmp/zulip-bootstrap.py <<PY" in values_text
    assert (
        'su zulip -c "cd /home/zulip/deployments/current && ./manage.py shell < '
        "/tmp/zulip-bootstrap.py"
        '"'
    ) in values_text
    assert "missing_default_streams" in values_text
    assert "missing_streams" in values_text
    assert "imageName: ghcr.io/cloudnative-pg/postgresql:16.4" in db_cluster_text
    assert "name: zulip-runtime" in runtime_secret_text
    assert "secretKey: rabbitmq-password" in runtime_secret_text
    assert "property: ZULIP_RABBITMQ_PASSWORD" in runtime_secret_text
    assert "secretKey: redis-password" in runtime_secret_text
    assert "property: ZULIP_REDIS_PASSWORD" in runtime_secret_text
    assert "secretKey: rabbitmq-erlang-cookie" in runtime_secret_text
    assert "property: ZULIP_RABBITMQ_ERLANG_COOKIE" in runtime_secret_text
    assert "verify_zulip_bootstrap" in run_text
    assert "ensure_zulip_bootstrap_streams" in run_text
    assert "zulip_jitsi_server_url" in run_text
    assert "realm.jitsi_server_url" in run_text
    assert "realm.video_chat_provider" in run_text
    assert "wait_for_zulip_realm" in run_text
    assert "find_statefulset_pod" in run_text
    assert "OnboardingUserMessage" in run_text
    assert "Missing Zulip onboarding messages" in run_text
    assert "create-users-and-groups.json" in run_text


def test_zulip_step_requests_kubeconfig_secret_injection():
    step_text = _read(ZULIP_STEP)

    assert "secrets:" in step_text
    assert "KUBECONFIG_FILE:" in step_text
    assert "scope: cluster" in step_text
    assert "item: kubeconfig" in step_text
    assert "attachment: kubeconfig" in step_text
    assert "format: file" in step_text


def test_outline_step_projects_a_real_oidc_backed_app():
    step_text = _read(OUTLINE_STEP)
    app_text = _read(OUTLINE_APP)
    deployment_text = _read(OUTLINE_DEPLOYMENT)
    secret_text = _read(OUTLINE_SECRET)
    db_cluster_text = _read(OUTLINE_DB_CLUSTER)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in step_text
    assert "openbao_read_global_secret_json outline" in step_text
    assert '--secret-name "outline"' in step_text
    assert (
        '--required-keys "OUTLINE_POSTGRESQL__USERNAME,OUTLINE_POSTGRESQL__PASSWORD,DATABASE_URL,REDIS_URL,SECRET_KEY,UTILS_SECRET,OIDC_CLIENT_ID,OIDC_CLIENT_SECRET"'
        in step_text
    )
    assert "create_or_update_provider()" in step_text
    assert 'slug "outline"' in step_text
    assert 'sed "s/__ZONE_NAME__/${public_zone_name}/g"' in step_text
    assert "apply-argocd-application.sh" in step_text
    assert '--application "outline"' in step_text
    assert "path: gitops/platform-apps/outline" in app_text
    assert "path: gitops/databases/outline" in app_text
    assert "value: https://outline.__ZONE_NAME__" in app_text
    assert "value: https://authentik.__ZONE_NAME__/application/o/outline/" in app_text
    assert "application/o/outline/end-session/" in app_text
    assert "kind: Application" in app_text
    assert "image: docker.getoutline.com/outlinewiki/outline:1.7.1" in deployment_text
    assert "OIDC_ISSUER_URL" in deployment_text
    assert "OIDC_LOGOUT_URI" in deployment_text
    assert "requests:" in deployment_text
    assert "cpu: 500m" in deployment_text
    assert "memory: 512Mi" in deployment_text
    assert 'cpu: "1"' in deployment_text
    assert "memory: 1Gi" in deployment_text
    assert "property: DATABASE_URL" in secret_text
    assert "property: REDIS_URL" in secret_text
    assert "property: SECRET_KEY" in secret_text
    assert "property: UTILS_SECRET" in secret_text
    assert "property: OIDC_CLIENT_ID" in secret_text
    assert "property: OIDC_CLIENT_SECRET" in secret_text
    assert "imageName: ghcr.io/cloudnative-pg/postgresql:16.4" in db_cluster_text


def test_pixelfed_step_and_secret_project_activitypub_and_bootstrap_keys():
    step_text = _read(PIXELFED_STEP)
    secret_text = _read(PIXELFED_SECRET)
    db_cluster_text = _read(PIXELFED_DB_CLUSTER)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in step_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in step_text
    assert "openbao_read_global_secret_json pixelfed" in step_text
    assert "pixelfed_secret_file=" in step_text
    assert '--secret-name "pixelfed"' in step_text
    assert (
        '--required-keys "APP_KEY,PIXELFED_POSTGRESQL__USERNAME,PIXELFED_POSTGRESQL__PASSWORD,PF_OIDC_CLIENT_ID,PF_OIDC_CLIENT_SECRET,PF_OIDC_AUTHORIZE_URL,PF_OIDC_TOKEN_URL,PF_OIDC_PROFILE_URL,PF_OIDC_LOGOUT_URL"'
        in step_text
    )
    assert "php artisan instance:actor" in step_text
    assert "php artisan passport:keys --force" in step_text
    assert "apply-argocd-application.sh" in step_text
    assert '--application "pixelfed"' in step_text
    assert "gitops/apps/pixelfed.yaml" in step_text

    assert "name: pixelfed-bootstrap" in secret_text
    assert "secretKey: APP_KEY" in secret_text
    assert "property: APP_KEY" in secret_text
    assert "property: PIXELFED_POSTGRESQL__USERNAME" in secret_text
    assert "property: PIXELFED_POSTGRESQL__PASSWORD" in secret_text
    assert "property: PF_OIDC_CLIENT_ID" in secret_text
    assert "property: PF_OIDC_CLIENT_SECRET" in secret_text
    assert "property: PF_OIDC_AUTHORIZE_URL" in secret_text
    assert "property: PF_OIDC_TOKEN_URL" in secret_text
    assert "property: PF_OIDC_PROFILE_URL" in secret_text
    assert "property: PF_OIDC_LOGOUT_URL" in secret_text

    assert "destinationPath: s3://twinbox-velero/pixelfed-db/" in db_cluster_text
    assert "imageName: ghcr.io/cloudnative-pg/postgresql:16.4" in db_cluster_text
