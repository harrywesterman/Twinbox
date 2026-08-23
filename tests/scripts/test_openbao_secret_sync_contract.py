import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SYNC_SCRIPT = REPO_ROOT / "scripts" / "manager" / "sync-openbao-global-secret.sh"
OPENBAO_HELPER = REPO_ROOT / "scripts" / "manager" / "openbao-secret-sync.sh"
UPGRADE_SCRIPT = REPO_ROOT / "scripts" / "manager" / "upgrade-cluster.sh"
GRAFANA_STEP = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh"
GRAFANA_SECRET = REPO_ROOT / "gitops" / "platform" / "grafana" / "externalsecret.yaml"
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
BESZEL_STEP = REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-beszel" / "run.sh"
BESZEL_BASTION_AGENT_SCRIPT = (
    REPO_ROOT / "scripts" / "manager" / "configure-bastion-beszel-agent.sh"
)
BESZEL_AGENT_SECRET = (
    REPO_ROOT / "gitops" / "platform-apps" / "beszel-agents" / "externalsecret.yaml"
)
BESZEL_AGENT_DAEMONSET = REPO_ROOT / "gitops" / "platform-apps" / "beszel-agents" / "daemonset.yaml"
TALOS_CATEGORY = REPO_ROOT / "categories" / "talos-cluster" / "category.yaml"
PIXELFED_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-pixelfed" / "run.sh"
MASTODON_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-mastodon" / "run.sh"
MASTODON_APP = REPO_ROOT / "gitops" / "apps" / "mastodon.yaml"
MASTODON_VALUES = REPO_ROOT / "gitops" / "values" / "mastodon.yaml"
MASTODON_NAMESPACE = REPO_ROOT / "gitops" / "platform-apps" / "mastodon" / "namespace.yaml"
MASTODON_KUSTOMIZATION = REPO_ROOT / "gitops" / "platform-apps" / "mastodon" / "kustomization.yaml"
MASTODON_INGRESSROUTE = REPO_ROOT / "gitops" / "platform-apps" / "mastodon" / "ingressroute.yaml"
MASTODON_FORWARDED_HEADERS = (
    REPO_ROOT / "gitops" / "platform-apps" / "mastodon" / "forwarded-headers-middleware.yaml"
)
MASTODON_RUNTIME_SECRET = (
    REPO_ROOT / "gitops" / "platform-apps" / "mastodon" / "externalsecret-runtime.yaml"
)
MASTODON_DB_SECRET = REPO_ROOT / "gitops" / "databases" / "mastodon" / "externalsecret.yaml"
MASTODON_DB_CLUSTER = REPO_ROOT / "gitops" / "databases" / "mastodon" / "cluster.yaml"
MASTODON_DB_OBJECTSTORE = REPO_ROOT / "gitops" / "databases" / "mastodon" / "objectstore.yaml"
ZULIP_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-zulip" / "step.yaml"
ZULIP_RUN = REPO_ROOT / "categories" / "apps" / "steps" / "install-zulip" / "run.sh"
ZULIP_APP = REPO_ROOT / "gitops" / "apps" / "zulip.yaml"
ZULIP_OPTIONAL_APP = REPO_ROOT / "gitops" / "optional-apps" / "zulip.yaml"
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


def _helm_template_zulip(chart_version: str) -> subprocess.CompletedProcess[str]:
    helm = shutil.which("helm")
    if helm is None:
        pytest.skip("helm is not available")

    env = os.environ.copy()
    with tempfile.TemporaryDirectory() as docker_config:
        env["DOCKER_CONFIG"] = docker_config
        return subprocess.run(
            [
                helm,
                "template",
                "zulip",
                "oci://ghcr.io/zulip/helm-charts/zulip",
                "--version",
                chart_version,
                "-f",
                str(ZULIP_VALUES),
                "--namespace",
                "zulip",
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )


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


def test_beszel_step_uses_hub_public_key_and_universal_token_secret():
    text = _read(BESZEL_STEP)
    bastion_agent_text = _read(BESZEL_BASTION_AGENT_SCRIPT)
    secret_text = _read(BESZEL_AGENT_SECRET)
    daemonset_text = _read(BESZEL_AGENT_DAEMONSET)

    assert "beszel_public_key_from_file" in text
    assert "/opt/twinbox/beszel/data/id_ed25519" in text
    assert 'beszel_local_url="${BESZEL_LOCAL_URL:-http://beszel:8090}"' in text
    assert 'source "$WORKSPACE_ROOT/scripts/manager/management-ip.sh"' in text
    assert "ensure_beszel_superuser" in text
    assert "/api/collections/_superusers/auth-with-password" in text
    assert "cluster_scope_id=" in text
    assert "read_first_admin_email" in text
    assert "create-users-and-groups.json" in text
    assert "beszel_upsert_user" in text
    assert "Ensuring Beszel user for the first Authentik admin" in text
    assert 'matching_mode: "strict"' in text
    assert "url: $redirect_uri" in text
    assert 'redirect_uri_type: "authorization"' in text
    assert 'PATCH "/core/applications/${beszel_application_slug}/"' in text
    assert 'PATCH "/core/applications/${existing_app_pk}/"' not in text
    assert 'beszel_api_get "/api/beszel/info"' in text
    assert "upsert_beszel_universal_token" in text
    assert "/api/collections/universal_tokens/records" in text
    assert "sync_beszel_system_users" in text
    assert "/api/collections/users/records?perPage=500" in text
    assert "/api/collections/systems/records?perPage=500" in text
    assert 'PATCH "/api/collections/systems/records/${system_id}"' in text
    assert "Reconciling Beszel user access to systems" in text
    assert text.index("Starting Beszel Management VM agent") < text.index(
        "Reconciling Beszel user access to systems"
    )
    assert "openssl rand -hex 32" in text
    assert '"hub_url": "$beszel_app_url"' in text
    assert "configure-bastion-beszel-agent.sh" in text
    assert '--cluster-id "$cluster_id"' in text
    assert '--agent-secret-file "$beszel_agent_secret_file"' in text
    assert '--beszel-version "$beszel_version"' in text
    assert '--secret-name "beszel-agent"' in text
    assert '--required-keys "key,token,hub_url"' in text
    assert "kubectl delete application beszel-agents" not in text
    assert "apply_beszel_traefik_route" in text
    assert "beszel-service.yaml" in text
    assert "beszel-endpoints.yaml" in text
    assert "beszel-ingressroute.yaml" in text
    assert "gitops/apps/platform-ingress.yaml" in text
    assert '--application "platform-ingress"' in text
    assert '--destination-namespace "argocd"' in text

    assert "apiVersion: external-secrets.io/v1" in secret_text
    assert "secretKey: hub_url" in secret_text
    assert "property: hub_url" in secret_text
    assert "name: HUB_URL" in daemonset_text
    assert "key: hub_url" in daemonset_text
    assert 'value: "https://beszel.__ZONE_NAME__"' not in daemonset_text

    assert "PINNED_BESZEL_VERSION" in bastion_agent_text
    assert "netbird-bastion-${CLUSTER_ID}.json" in bastion_agent_text
    assert "No NetBird bastion secret found" in bastion_agent_text
    assert "SSH_PRIVATE_KEY" in bastion_agent_text
    assert "beszel-bastion-ssh-key" in bastion_agent_text
    assert "SYSTEM_NAME=%s" in bastion_agent_text
    assert "twinbox-netbird-bastion" in bastion_agent_text
    assert "DISABLE_SSH=true" in bastion_agent_text
    assert "image: henrygd/beszel-agent:${BESZEL_VERSION}" in bastion_agent_text
    assert "network_mode: host" in bastion_agent_text
    assert "/var/run/docker.sock:/var/run/docker.sock:ro" in bastion_agent_text


def test_gitops_secret_consumers_now_reference_cluster_secret_store_openbao():
    grafana_text = _read(GRAFANA_SECRET)
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
    optional_app_text = _read(ZULIP_OPTIONAL_APP)
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
        '--required-keys "ZULIP_RABBITMQ_PASSWORD,ZULIP_RABBITMQ_ERLANG_COOKIE,ZULIP_REDIS_PASSWORD,ZULIP_MEMCACHED_PASSWORD"'
        in run_text
    )
    assert "wait_for_named_resource_ready" in run_text
    assert 'zulip_manifest_path="$WORKSPACE_ROOT/gitops/optional-apps/zulip.yaml"' in run_text
    assert 'wait_for_named_resource_ready "databases" "cluster" "zulip-db"' in run_text
    assert (
        'wait_for_named_resource_ready "databases" "externalsecret" "zulip-db-credentials"'
        in run_text
    )
    assert 'wait_for_deployment_rollout "databases" "zulip-db-pooler-ro"' in run_text
    assert 'wait_for_deployment_rollout "databases" "zulip-db-pooler-rw"' in run_text
    assert 'wait_for_named_resource_ready "zulip" "externalsecret" "zulip-config"' in run_text
    assert (
        'wait_for_named_resource_ready "zulip" "externalsecret" "zulip-db-credentials"' in run_text
    )
    assert 'wait_for_named_resource_ready "zulip" "externalsecret" "zulip-runtime"' in run_text
    assert "zulip_config_secret_json" in run_text
    assert "zulip_runtime_secret_json" in run_text
    assert "ensure_zulip_agent_bot" in run_text
    assert "read_zulip_owner_api_credentials" in run_text
    assert "SELECT delivery_email, api_key FROM zerver_userprofile" in run_text
    assert "sync_zulip_bot_to_agents_secret" in run_text
    assert 'zulip_agent_stream="${ZULIP_AGENT_STREAM:-Twinbox AI}"' in run_text
    assert 'zulip_agent_base_url="${ZULIP_AGENT_BASE_URL:-$zulip_host}"' in run_text
    assert (
        'zulip_provisioning_base_url="${ZULIP_PROVISIONING_BASE_URL:-http://127.0.0.1}"' in run_text
    )
    assert "/api/v1/users/me/subscriptions" in run_text
    assert "/api/v1/bots" in run_text
    assert "ZULIP_BASE_URL: $base_url" in run_text
    assert "ZULIP_BOT_EMAIL: $bot_email" in run_text
    assert "ZULIP_BOT_API_KEY: $bot_api_key" in run_text
    assert '--secret-name "twinbox-agents"' in run_text
    assert (
        '--required-keys "ZULIP_BASE_URL,ZULIP_BOT_EMAIL,ZULIP_BOT_API_KEY,ZULIP_STREAM"'
        in run_text
    )
    assert "rollout restart deployment/twinbox-agents" in run_text
    assert "LOADBALANCER_IPS" not in run_text
    assert "__ZULIP_RABBITMQ_PASSWORD__" not in run_text
    assert "__ZULIP_REDIS_PASSWORD__" not in run_text

    assert "kind: ApplicationSet" in app_text
    assert "name: zulip-set" in app_text
    assert "repoURL: oci://ghcr.io/zulip/helm-charts/zulip" in app_text
    assert "path: ." in app_text
    chart_version = re.search(r'targetRevision:\s*"([^"]+)"', app_text).group(1)
    assert f'targetRevision: "{chart_version}"' in optional_app_text
    assert "path: gitops/platform-apps/zulip" in app_text
    assert (
        'SETTING_EXTERNAL_HOST: zulip.{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in app_text
    )
    assert (
        'SETTING_ZULIP_ADMINISTRATOR: admin@{{index .metadata.annotations "twinbox.io/public-zone-name"}}'
        in app_text
    )
    expected_zulip_csrf_trusted_origins = (
        "SETTING_CSRF_TRUSTED_ORIGINS: '[\"https://zulip."
        '{{index .metadata.annotations "twinbox.io/public-zone-name"}}"]\''
    )
    assert expected_zulip_csrf_trusted_origins in app_text
    assert expected_zulip_csrf_trusted_origins in optional_app_text
    assert "ZULIP_AUTH_BACKENDS: GenericOpenIdConnectBackend" in app_text
    assert "ZULIP_AUTH_BACKENDS: GenericOpenIdConnectBackend" in optional_app_text
    assert "ServerSideApply=true" in app_text
    assert "ServerSideApply=true" in optional_app_text
    assert 'TRUST_GATEWAY_IP: "True"' not in app_text
    assert 'TRUST_GATEWAY_IP: "True"' not in optional_app_text
    assert 'LOADBALANCER_IPS: "{{index .metadata.annotations "twinbox.io/pod-cidr"}}"' in app_text
    assert (
        'LOADBALANCER_IPS: "{{index .metadata.annotations "twinbox.io/pod-cidr"}}"'
        in optional_app_text
    )
    assert "pod-cidr" in app_text
    assert "pod-cidr" in optional_app_text
    assert "SETTING_RUNNING_IN_HELM" not in app_text
    assert "SETTING_RUNNING_IN_HELM" not in optional_app_text
    assert "ZULIP_DEFAULT_REALM_OWNER_EMAIL:" not in app_text
    assert "ZULIP_DEFAULT_REALM_OWNER_NAME:" not in app_text
    assert "existingPasswordSecret: zulip-runtime" in app_text
    assert "existingSecretPasswordKey: rabbitmq-password" in app_text
    assert "existingErlangSecret: zulip-runtime" in app_text
    assert "existingSecretErlangKey: rabbitmq-erlang-cookie" in app_text
    assert "existingSecret: zulip-runtime" in app_text
    assert "existingSecretPasswordKey: redis-password" in app_text
    assert "LOADBALANCER_IPS:" in app_text
    assert "LOADBALANCER_IPS:" in optional_app_text
    assert "SETTING_LOADBALANCER_IPS" not in values_text
    assert "SETTING_AUTHENTICATION_BACKENDS" not in values_text
    assert "accessModes:" in values_text
    assert "accessMode:" not in values_text
    assert "06-patch-nginx-trusted-proto" not in values_text
    assert "trusted_proto_entries" not in values_text
    assert "livenessProbe:" in values_text
    assert "failureThreshold: 15" in values_text
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
    assert "SECRETS_rabbitmq_password:" not in values_text
    assert "SECRETS_redis_password:" not in values_text
    assert "SETTING_MEMCACHED_USERNAME:" not in values_text
    assert "SECRETS_memcached_password:" not in values_text
    assert "usePasswordFiles: false" in values_text
    assert "containerSecurityContext:" in values_text
    assert "readOnlyRootFilesystem: false" in values_text
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
    assert "conversionStrategy: Default" in runtime_secret_text
    assert "decodingStrategy: None" in runtime_secret_text
    assert "metadataPolicy: None" in runtime_secret_text
    assert "nullBytePolicy: Ignore" in runtime_secret_text
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


def test_zulip_values_render_against_pinned_chart_version():
    app_text = _read(ZULIP_APP)
    chart_version = re.search(r'targetRevision:\s*"([^"]+)"', app_text).group(1)
    result = _helm_template_zulip(chart_version)
    assert result.returncode == 0, result.stderr


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
    ingressroute_text = _read(OUTLINE_PLATFORM_DIR / "ingressroute.yaml")
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
    assert "PROXY_HEADERS_TRUSTED" in deployment_text
    assert "outline-forwarded-headers" in ingressroute_text
    forwarded_headers_text = _read(OUTLINE_PLATFORM_DIR / "forwarded-headers-middleware.yaml")
    assert "X-Forwarded-Proto: https" in forwarded_headers_text
    assert "requests:" in deployment_text
    assert "cpu: 100m" in deployment_text
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


def test_mastodon_step_bootstraps_runtime_and_admin_secret_via_openbao():
    step_text = _read(MASTODON_STEP)
    app_text = _read(MASTODON_APP)
    values_text = _read(MASTODON_VALUES)
    namespace_text = _read(MASTODON_NAMESPACE)
    kustomization_text = _read(MASTODON_KUSTOMIZATION)
    ingressroute_text = _read(MASTODON_INGRESSROUTE)
    forwarded_headers_text = _read(MASTODON_FORWARDED_HEADERS)
    runtime_secret_text = _read(MASTODON_RUNTIME_SECRET)
    db_secret_text = _read(MASTODON_DB_SECRET)
    db_cluster_text = _read(MASTODON_DB_CLUSTER)
    db_objectstore_text = _read(MASTODON_DB_OBJECTSTORE)

    assert "openbao_read_global_secret_json mastodon" in step_text
    assert "sync-openbao-global-secret.sh" in step_text
    assert '--secret-name "mastodon"' in step_text
    assert 'mastodon_admin_password=""' in step_text
    assert "gitops/platform-apps/mastodon/namespace.yaml" in step_text
    assert "gitops/databases/shared/namespace.yaml" in step_text
    assert "gitops/platform-apps/mastodon/externalsecret-runtime.yaml" in step_text
    assert "gitops/platform-apps/mastodon/externalsecret-s3.yaml" in step_text
    assert "gitops/databases/mastodon/externalsecret.yaml" in step_text
    assert 'openbao_wait_for_external_secret_ready "mastodon" "mastodon-runtime"' in step_text
    assert 'openbao_wait_for_secret "mastodon-runtime" "mastodon"' in step_text
    assert 'openbao_wait_for_external_secret_ready "mastodon" "mastodon-s3"' in step_text
    assert 'openbao_wait_for_secret "mastodon-s3" "mastodon"' in step_text
    assert (
        'openbao_wait_for_external_secret_ready "databases" "mastodon-db-credentials"' in step_text
    )
    assert 'openbao_wait_for_secret "mastodon-db-credentials" "databases"' in step_text
    assert (
        '--required-keys "MASTODON_POSTGRESQL__USERNAME,MASTODON_POSTGRESQL__PASSWORD,REDIS_PASSWORD,SECRET_KEY_BASE,OTP_SECRET,VAPID_PRIVATE_KEY,VAPID_PUBLIC_KEY,ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,MASTODON_OIDC_CLIENT_ID,MASTODON_OIDC_CLIENT_SECRET,MASTODON_ADMIN_USERNAME"'
        in step_text
    )
    assert (
        '--required-keys "MASTODON_POSTGRESQL__USERNAME,MASTODON_POSTGRESQL__PASSWORD,REDIS_PASSWORD,SECRET_KEY_BASE,OTP_SECRET,VAPID_PRIVATE_KEY,VAPID_PUBLIC_KEY,ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY,ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT,MASTODON_OIDC_CLIENT_ID,MASTODON_OIDC_CLIENT_SECRET,MASTODON_ADMIN_USERNAME,MASTODON_ADMIN_PASSWORD"'
        in step_text
    )
    assert "wait_for_deployment_image" in step_text
    assert "bundle" in step_text
    assert "db:migrate db:seed" in step_text
    assert "SKIP_POST_DEPLOYMENT_MIGRATIONS" not in step_text
    assert "kubectl -n mastodon exec deployment/mastodon-web" in step_text
    assert "bin/tootctl" in step_text
    assert (
        'accounts modify "$mastodon_admin_username" --approve --confirm --role Owner --reset-password'
        in step_text
    )
    assert (
        'accounts create "$mastodon_admin_username" --email "$mastodon_admin_email" --confirmed --role Owner --approve'
        in step_text
    )
    assert "MASTODON_ADMIN_PASSWORD" in step_text
    assert "path: gitops/platform-apps/mastodon" in app_text
    assert "path: gitops/databases/mastodon" in app_text
    assert "mastodon.__ZONE_NAME__" in app_text
    assert "\n          externalAuth:\n            oidc:" in app_text
    assert "\n            externalAuth:" not in app_text
    assert "authentik.__ZONE_NAME__/application/o/mastodon/" in app_text
    assert "client_id: from-mastodon-runtime-secret" in app_text
    assert "client_secret: from-mastodon-runtime-secret" in app_text
    assert "__MASTODON_OIDC_CLIENT_ID__" not in app_text
    assert "__MASTODON_OIDC_CLIENT_SECRET__" not in app_text
    assert "elasticsearch:\n  enabled: false" in values_text
    assert "dbMigrate:\n      enabled: false" in values_text
    assert "pod-security.kubernetes.io/enforce: baseline" in namespace_text
    assert "pod-security.kubernetes.io/audit: baseline" in namespace_text
    assert "pod-security.kubernetes.io/warn: baseline" in namespace_text
    assert "forwarded-headers-middleware.yaml" in kustomization_text
    assert ingressroute_text.count("name: mastodon-web\n          port: 3000") == 2
    assert "name: mastodon-web\n          port: 80" not in ingressroute_text
    assert ingressroute_text.count("name: mastodon-netbird-forwarded-headers") == 2
    assert "name: mastodon-netbird-forwarded-headers" in forwarded_headers_text
    assert "X-Forwarded-Proto: https" in forwarded_headers_text
    assert 'X-Forwarded-Port: "443"' in forwarded_headers_text
    assert "mastodon-runtime" in runtime_secret_text
    assert "secretKey: password" in runtime_secret_text
    assert "property: MASTODON_POSTGRESQL__PASSWORD" in runtime_secret_text
    assert "property: REDIS_PASSWORD" in runtime_secret_text
    assert "property: SECRET_KEY_BASE" in runtime_secret_text
    assert "property: OTP_SECRET" in runtime_secret_text
    assert "property: VAPID_PRIVATE_KEY" in runtime_secret_text
    assert "property: VAPID_PUBLIC_KEY" in runtime_secret_text
    assert "property: ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" in runtime_secret_text
    assert "property: ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" in runtime_secret_text
    assert "property: ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" in runtime_secret_text
    assert "secretKey: OIDC_CLIENT_ID" in runtime_secret_text
    assert "property: MASTODON_OIDC_CLIENT_ID" in runtime_secret_text
    assert "secretKey: OIDC_CLIENT_SECRET" in runtime_secret_text
    assert "property: MASTODON_OIDC_CLIENT_SECRET" in runtime_secret_text
    assert "name: mastodon-db-credentials" in db_secret_text
    assert "property: MASTODON_POSTGRESQL__USERNAME" in db_secret_text
    assert "property: MASTODON_POSTGRESQL__PASSWORD" in db_secret_text
    assert "barmanObjectName: mastodon-db-objectstore" in db_cluster_text
    assert "instances: 2" in db_cluster_text
    assert "cpu: 100m" in db_cluster_text
    assert "memory: 256Mi" in db_cluster_text
    assert "cpu: 500m" in db_cluster_text
    assert "memory: 1Gi" in db_cluster_text
    assert "destinationPath: s3://twinbox-velero/mastodon-db/" in db_objectstore_text
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

    db_objectstore_text = (
        REPO_ROOT / "gitops" / "databases" / "pixelfed" / "objectstore.yaml"
    ).read_text(encoding="utf-8")
    assert "barmanObjectName: pixelfed-db-objectstore" in db_cluster_text
    assert "destinationPath: s3://twinbox-velero/pixelfed-db/" in db_objectstore_text
    assert "imageName: ghcr.io/cloudnative-pg/postgresql:16.4" in db_cluster_text
