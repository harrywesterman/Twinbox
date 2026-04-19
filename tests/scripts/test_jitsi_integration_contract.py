from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
JITSI_APP_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-jitsi" / "step.yaml"
JITSI_JOURNEY_STEP = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-jitsi" / "step.yaml"
)
JITSI_RUN = REPO_ROOT / "categories" / "apps" / "steps" / "install-jitsi" / "run.sh"
JITSI_APP = REPO_ROOT / "gitops" / "apps" / "jitsi.yaml"
JITSI_VALUES = REPO_ROOT / "gitops" / "values" / "jitsi.yaml"
JITSI_PLATFORM_DIR = REPO_ROOT / "gitops" / "platform-apps" / "jitsi"
JITSI_KUSTOMIZATION = JITSI_PLATFORM_DIR / "kustomization.yaml"
JITSI_NAMESPACE = JITSI_PLATFORM_DIR / "namespace.yaml"
JITSI_EXTERNAL_SECRET = JITSI_PLATFORM_DIR / "externalsecret.yaml"
JITSI_BROKER_DEPLOYMENT = JITSI_PLATFORM_DIR / "auth-deployment.yaml"
JITSI_BROKER_SERVICE = JITSI_PLATFORM_DIR / "auth-service.yaml"
JITSI_INGRESS = JITSI_PLATFORM_DIR / "ingressroute.yaml"
JITSI_IMAGE_DOCKERFILE = REPO_ROOT / "images" / "jitsi-openid" / "Dockerfile"
JITSI_IMAGE_PATCH = (
    REPO_ROOT / "images" / "jitsi-openid" / "0001-room-scoped-short-lived-jwt.patch"
)
DOCKER_PUBLISH_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "docker-publish.yml"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_install_jitsi_steps_are_backed_by_a_real_runner_and_cluster_secret_injection():
    app_step_text = _read(JITSI_APP_STEP)
    journey_step_text = _read(JITSI_JOURNEY_STEP)

    assert "Placeholder step" not in app_step_text
    assert "Placeholder step" not in journey_step_text
    assert "categories/apps/steps/install-jitsi/run.sh" in app_step_text
    assert "categories/apps/steps/install-jitsi/run.sh" in journey_step_text
    assert "summary: Install Jitsi" in app_step_text
    assert "summary: Install Jitsi" in journey_step_text
    assert "install-secret-sync" in app_step_text
    assert "install-authentik-idp" in app_step_text
    assert "create-users-and-groups" in app_step_text
    assert "choose-ingress-route" in app_step_text
    assert "install-freshrss" not in app_step_text
    assert "install-secret-sync" in journey_step_text
    assert "install-authentik-idp" in journey_step_text
    assert "create-users-and-groups" in journey_step_text
    assert "choose-ingress-route" in journey_step_text
    assert "install-freshrss" not in journey_step_text
    assert "KUBECONFIG_FILE:" in app_step_text
    assert "scope: cluster" in app_step_text
    assert "item: kubeconfig" in app_step_text
    assert "attachment: kubeconfig" in app_step_text
    assert "format: file" in app_step_text
    assert "url_template: https://jitsi.__ZONE_NAME__" in app_step_text


def test_install_jitsi_runner_provisions_authentik_groups_scope_mapping_and_openbao_state():
    run_text = _read(JITSI_RUN)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"' in run_text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in run_text
    assert 'jitsi_hosts_group_name="jitsi-hosts"' in run_text
    assert 'find_scope_mapping_pk_by_name()' in run_text
    assert 'create_or_update_scope_mapping()' in run_text
    assert 'ensure_group()' in run_text
    assert 'ensure_group_binding()' in run_text
    assert 'authentik_api_get "/core/applications/${application_slug}/"' in run_text
    assert 'authentik_api_write PATCH "/core/applications/${application_slug}/"' in run_text
    assert 'response="$(authentik_api_get "/providers/oauth2/?page_size=100")" || return 1' in run_text
    assert 'response="$(authentik_api_get "/policies/bindings/?page_size=200")" || return 1' in run_text
    assert 'existing_pk="$(find_policy_binding_pk "$target_uuid" "$group_id")"' in run_text
    assert 'authentik_api_write PATCH "/policies/bindings/${existing_pk}/"' not in run_text
    assert 'jicofo_auth_password="$(openssl rand -hex 16)"' in run_text
    assert 'jvb_auth_user="jvb"' in run_text
    assert 'jvb_auth_password="$(openssl rand -hex 16)"' in run_text
    assert 'JICOFO_AUTH_PASSWORD: $jicofo_auth_password' in run_text
    assert 'JVB_AUTH_USER: $jvb_auth_user' in run_text
    assert 'JVB_AUTH_PASSWORD: $jvb_auth_password' in run_text
    assert 'sync-openbao-global-secret.sh' in run_text
    assert '--secret-name "jitsi-auth"' in run_text
    assert 'jitsi_secret_file="${secrets_dir}/jitsi-auth-${cluster_id}.json"' in run_text
    assert 'JICOFO_AUTH_PASSWORD,JVB_AUTH_USER,JVB_AUTH_PASSWORD' in run_text
    assert 'kubectl apply -f "$jitsi_namespace_manifest"' in run_text
    assert 'kubectl apply -f "$jitsi_externalsecret_manifest"' in run_text
    assert 'kubectl -n jitsi wait --for=condition=Ready externalsecret/jitsi-auth --timeout=10m' in run_text
    assert 'gitops/apps/jitsi.yaml' in run_text
    assert 'Provisioning Authentik OIDC client for Jitsi broker' in run_text


def test_jitsi_gitops_application_and_values_enable_token_auth_guests_and_broker_redirects():
    app_text = _read(JITSI_APP)
    values_text = _read(JITSI_VALUES)

    assert "kind: Application" in app_text
    assert "name: jitsi" in app_text
    assert "chart: jitsi-meet" in app_text
    assert 'targetRevision: "2.15.0"' in app_text
    assert "path: gitops/platform-apps/jitsi" in app_text
    assert "publicURL: https://jitsi.__ZONE_NAME__" in app_text
    assert "domain: jitsi.__ZONE_NAME__" in app_text
    assert "guestDomain: guest.jitsi.__ZONE_NAME__" in app_text
    assert "TOKEN_AUTH_URL: https://auth-jitsi.__ZONE_NAME__/room/{room}" in app_text

    assert "fullnameOverride: jitsi" in values_text
    assert "enableAuth: true" in values_text
    assert "enableGuests: true" in values_text
    assert "existingSecretName: jitsi-auth" in values_text
    assert "jicofo:" in values_text
    assert "xmpp:" in values_text
    assert "WAIT_FOR_HOST_DISABLE_AUTO_OWNERS" in values_text
    assert "ENABLE_AUTO_OWNER" in values_text
    assert "XMPP_MODULES" in values_text
    assert "persistent_lobby" in values_text
    assert "frozen_nick" in values_text
    assert "XMPP_MUC_MODULES" in values_text
    assert "muc_wait_for_host" in values_text
    assert "token_affiliation" in values_text
    assert "token_no_wildcard" in values_text
    assert "useHostPort: true" in values_text
    assert "useNodeIP: true" in values_text
    assert "initialDelaySeconds: 45" in values_text
    assert "initialDelaySeconds: 20" in values_text
    assert "timeoutSeconds: 5" in values_text
    assert "enabled: false" in values_text
    assert "enableUserRolesBasedOnToken = true;" in values_text


def test_jitsi_platform_overlay_provides_broker_secret_sync_service_and_ingress():
    kustomization_text = _read(JITSI_KUSTOMIZATION)
    namespace_text = _read(JITSI_NAMESPACE)
    external_secret_text = _read(JITSI_EXTERNAL_SECRET)
    deployment_text = _read(JITSI_BROKER_DEPLOYMENT)
    service_text = _read(JITSI_BROKER_SERVICE)
    ingress_text = _read(JITSI_INGRESS)

    assert "namespace.yaml" in kustomization_text
    assert "externalsecret.yaml" in kustomization_text
    assert "auth-deployment.yaml" in kustomization_text
    assert "auth-service.yaml" in kustomization_text
    assert "ingressroute.yaml" in kustomization_text

    assert "kind: Namespace" in namespace_text
    assert "name: jitsi" in namespace_text
    assert "kubernetes.io/metadata.name: jitsi" in namespace_text
    assert "pod-security.kubernetes.io/enforce: privileged" in namespace_text
    assert "pod-security.kubernetes.io/audit: privileged" in namespace_text
    assert "pod-security.kubernetes.io/warn: privileged" in namespace_text

    assert "kind: ExternalSecret" in external_secret_text
    assert "name: jitsi-auth" in external_secret_text
    assert "kind: ClusterSecretStore" in external_secret_text
    assert "name: openbao" in external_secret_text
    assert "key: twinbox/global/jitsi-auth" in external_secret_text
    assert "secretKey: JWT_APP_SECRET" in external_secret_text
    assert "secretKey: JITSI_SECRET" in external_secret_text
    assert "secretKey: JITSI_SUB" in external_secret_text
    assert "secretKey: ISSUER_URL" in external_secret_text
    assert "secretKey: CLIENT_ID" in external_secret_text
    assert "secretKey: CLIENT_SECRET" in external_secret_text
    assert "secretKey: BASE_URL" in external_secret_text
    assert "secretKey: JICOFO_AUTH_PASSWORD" in external_secret_text
    assert "secretKey: JVB_AUTH_USER" in external_secret_text
    assert "secretKey: JVB_AUTH_PASSWORD" in external_secret_text
    assert "conversionStrategy: Default" in external_secret_text
    assert "decodingStrategy: None" in external_secret_text
    assert "metadataPolicy: None" in external_secret_text

    assert "kind: Deployment" in deployment_text
    assert "name: auth-jitsi" in deployment_text
    assert "ghcr.io/harrywesterman/twinbox-manager-worker:jitsi-openid-latest" in deployment_text
    assert "name: jitsi-auth" in deployment_text
    assert 'value: "0.0.0.0:3000"' in deployment_text
    assert 'value: "openid profile email jitsi"' in deployment_text

    assert "kind: Service" in service_text
    assert "name: auth-jitsi" in service_text
    assert "port: 3000" in service_text

    assert "Host(`jitsi.__ZONE_NAME__`)" in ingress_text
    assert "Host(`auth-jitsi.__ZONE_NAME__`)" in ingress_text
    assert "name: jitsi-web" in ingress_text
    assert "name: auth-jitsi" in ingress_text
    assert "webwiredoor" in ingress_text
    assert "webtailscale" in ingress_text


def test_jitsi_openid_image_is_pinned_and_patched_for_room_scoped_short_lived_tokens():
    workflow_text = _read(DOCKER_PUBLISH_WORKFLOW)
    dockerfile_text = _read(JITSI_IMAGE_DOCKERFILE)
    patch_text = _read(JITSI_IMAGE_PATCH)

    assert "image_name: twinbox-jitsi-openid" in workflow_text
    assert "package_name: twinbox-manager-worker" in workflow_text
    assert "context: ./images/jitsi-openid" in workflow_text
    assert "dockerfile: ./images/jitsi-openid/Dockerfile" in workflow_text
    assert "value=jitsi-openid-latest" in workflow_text
    assert "type=sha,prefix=jitsi-openid-" in workflow_text

    assert "ARG JITSI_OPENID_REF=5a023e2eb51dfbeb551d04861c11f52e886b53d6" in dockerfile_text
    assert "COPY 0001-room-scoped-short-lived-jwt.patch" in dockerfile_text
    assert "git apply" in dockerfile_text
    assert "https://github.com/MarcelCoding/jitsi-openid.git" in dockerfile_text

    assert "session.room.clone()" in patch_text
    assert 'Duration::minutes(15)' in patch_text
