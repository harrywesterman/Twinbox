from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SYNC_SCRIPT = REPO_ROOT / "scripts" / "manager" / "sync-openbao-global-secret.sh"
GRAFANA_STEP = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-grafana" / "run.sh"
)
WIREDOOR_STEP = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-wiredoor-gateway"
    / "run.sh"
)
GRAFANA_SECRET = (
    REPO_ROOT / "gitops" / "platform" / "grafana" / "externalsecret.yaml"
)
WIREDOOR_SECRET = (
    REPO_ROOT / "gitops" / "apps" / "wiredoor-gateway-secret" / "externalsecret.yaml"
)
TRAEFIK_SECRET = (
    REPO_ROOT / "gitops" / "platform" / "traefik" / "traefik-dashboard-externalsecret.yaml"
)
ZULIP_STEP = (
    REPO_ROOT / "categories" / "talos-cluster" / "steps" / "install-zulip" / "step.yaml"
)
REMOVED_PLACEHOLDER_STEP = (
    REPO_ROOT
    / "categories"
    / "talos-cluster"
    / "steps"
    / "install-vaultwarden-app"
    / "step.yaml"
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


def test_grafana_step_generates_and_syncs_an_oidc_secret():
    text = _read(GRAFANA_STEP)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in text
    assert 'grafana_secret_file="$BOOTSTRAP_ROOT/secrets/global/grafana-oidc-${cluster_id}.json"' in text
    assert "openssl rand -hex 16" in text
    assert "openssl rand -hex 24" in text
    assert "Provisioning Authentik OIDC client for Grafana" in text
    assert '"GF_AUTH_GENERIC_OAUTH_CLIENT_ID": $oauth_client_id' in text
    assert '"GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": $oauth_client_secret' in text
    assert '"GF_SECURITY_ADMIN_USER": $admin_user' in text
    assert '"GF_SECURITY_ADMIN_PASSWORD": $admin_password' in text
    assert "scripts/manager/sync-openbao-global-secret.sh" in text
    assert '--secret-name "grafana-oidc"' in text
    assert '--required-keys "GF_AUTH_DISABLE_LOGIN_FORM,GF_AUTH_OAUTH_AUTO_LOGIN,GF_AUTH_BASIC_ENABLED,GF_USERS_AUTO_ASSIGN_ORG_ROLE,GF_AUTH_GENERIC_OAUTH_ENABLED,GF_AUTH_GENERIC_OAUTH_NAME,GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP,GF_AUTH_GENERIC_OAUTH_CLIENT_ID,GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET,GF_AUTH_GENERIC_OAUTH_SCOPES,GF_AUTH_GENERIC_OAUTH_AUTH_URL,GF_AUTH_GENERIC_OAUTH_TOKEN_URL,GF_AUTH_GENERIC_OAUTH_API_URL,GF_SECURITY_ADMIN_USER,GF_SECURITY_ADMIN_PASSWORD"' in text
    assert (
        'kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-oidc --timeout=10m'
        in text
    )


def test_wiredoor_step_requires_url_generates_token_and_syncs_to_openbao():
    text = _read(WIREDOOR_STEP)

    assert 'mkdir -p "$(dirname "$wiredoor_secret_file")"' in text
    assert 'if [[ ! -f "$wiredoor_secret_file" ]]; then' in text
    assert 'wiredoor_url="${WIREDOOR_URL:-${TWINBOX_WIREDOOR_URL:-}}"' in text
    assert "openssl rand -hex 24" in text
    assert (
        'wiredoor_secret_file="$BOOTSTRAP_ROOT/secrets/global/wiredoor-gateway.json"'
        in text
    )
    assert "WIREDOOR_URL missing in $wiredoor_secret_file" in text
    assert "scripts/manager/sync-openbao-global-secret.sh" in text
    assert '--secret-name "wiredoor-gateway"' in text
    assert '--required-keys "WIREDOOR_URL,TOKEN"' in text


def test_gitops_secret_consumers_now_reference_cluster_secret_store_openbao():
    grafana_text = _read(GRAFANA_SECRET)
    wiredoor_text = _read(WIREDOOR_SECRET)
    traefik_text = _read(TRAEFIK_SECRET)

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


def test_removed_placeholder_step_is_absent_from_the_journey():
    assert not REMOVED_PLACEHOLDER_STEP.exists()
    assert "- install-immich" in _read(ZULIP_STEP)
