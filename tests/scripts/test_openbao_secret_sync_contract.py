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
    REPO_ROOT / "gitops" / "apps" / "grafana-secret" / "externalsecret.yaml"
)
WIREDOOR_SECRET = (
    REPO_ROOT / "gitops" / "apps" / "wiredoor-gateway-secret" / "externalsecret.yaml"
)
TRAEFIK_SECRET = (
    REPO_ROOT
    / "gitops"
    / "routes"
    / "templates"
    / "traefik-dashboard-externalsecret.yaml"
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


def test_grafana_step_generates_and_syncs_a_bootstrap_secret():
    text = _read(GRAFANA_STEP)

    assert 'grafana_secret_file="$BOOTSTRAP_ROOT/secrets/global/grafana.json"' in text
    assert "openssl rand -hex 16" in text
    assert '"admin-user": $admin_user' in text
    assert '"admin-password": $admin_password' in text
    assert "scripts/manager/sync-openbao-global-secret.sh" in text
    assert '--secret-name "grafana"' in text
    assert '--required-keys "admin-user,admin-password"' in text


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
    assert "property: admin-user" in grafana_text
    assert "property: admin-password" in grafana_text

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
