from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_docker_compose_mounts_categories_and_host_cron_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "WORKSPACE_ROOT=/opt/twinbox" in text
    assert "./categories:/opt/twinbox/categories:ro" in text
    assert "TWINBOX_HOST_REPO_ROOT=${TWINBOX_HOST_REPO_ROOT}" in text
    assert "/etc/cron.d:/host/etc/cron.d" in text


def test_docker_compose_includes_vaultwarden_secret_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "twinbox-vaultwarden" in text
    assert "vaultwarden/server:${VAULTWARDEN_IMAGE_TAG:-1.35.4}" in text
    assert "127.0.0.1:${VAULTWARDEN_LOCAL_PORT:-8222}:80" in text
    assert "TWINBOX_SECRET_BACKEND=${TWINBOX_SECRET_BACKEND:-vaultwarden}" in text
    assert "VAULTWARDEN_SERVER_URL=${VAULTWARDEN_SERVER_URL:-http://vaultwarden:80}" in text
    assert "VAULTWARDEN_CLIENTID_FILE=${VAULTWARDEN_CLIENTID_FILE:-/opt/twinbox/bootstrap/vaultwarden-client-id}" in text
    assert "BITWARDENCLI_APPDATA_DIR=${MANAGER_API_BITWARDENCLI_APPDATA_DIR:-/opt/twinbox/bootstrap/bw-runtime-api}" in text
    assert "BITWARDENCLI_APPDATA_DIR=${MANAGER_WORKER_BITWARDENCLI_APPDATA_DIR:-/opt/twinbox/bootstrap/bw-runtime-worker}" in text
    assert "./bootstrap:/opt/twinbox/bootstrap" in text


def test_env_example_includes_host_repo_root():
    text = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")

    assert "TWINBOX_HOST_REPO_ROOT=" in text


def test_env_example_includes_vaultwarden_bootstrap_contract():
    text = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")

    assert "TWINBOX_SECRET_BACKEND=vaultwarden" in text
    assert "VAULTWARDEN_IMAGE_TAG=1.35.4" in text
    assert "VAULTWARDEN_LOCAL_PORT=8222" in text
    assert "VAULTWARDEN_PASSWORD_FILE=/opt/twinbox/bootstrap/vaultwarden-password" in text
    assert "VAULTWARDEN_CLIENTID_FILE=/opt/twinbox/bootstrap/vaultwarden-client-id" in text
    assert "VAULTWARDEN_CLIENTSECRET_FILE=/opt/twinbox/bootstrap/vaultwarden-client-secret" in text
    assert "VAULTWARDEN_READY_FILE=/opt/twinbox/bootstrap/vaultwarden-ready" in text
    assert "BITWARDENCLI_APPDATA_DIR=/opt/twinbox/bootstrap/bw-runtime" in text


def test_bootstrap_vm_sets_host_repo_root_when_missing():
    text = (REPO_ROOT / "scripts" / "bootstrap-vm.sh").read_text(encoding="utf-8")

    assert 'if ! grep -q "^TWINBOX_HOST_REPO_ROOT=" .env; then' in text
    assert 'printf \'\\nTWINBOX_HOST_REPO_ROOT=%s\\n\' "$TARGET_DIR" >> .env' in text


def test_bootstrap_vm_starts_vaultwarden_before_full_stack():
    text = (REPO_ROOT / "scripts" / "bootstrap-vm.sh").read_text(encoding="utf-8")

    assert "docker compose up -d vaultwarden" in text
    assert "./scripts/bootstrap-vaultwarden.sh" in text


def test_start_manager_bootstraps_vaultwarden_before_compose_up():
    text = (REPO_ROOT / "scripts" / "start-manager.sh").read_text(encoding="utf-8")

    assert "docker compose up -d vaultwarden" in text
    assert "./scripts/bootstrap-vaultwarden.sh" in text


def test_start_manager_uses_openssl_for_first_run_vaultwarden_password():
    text = (REPO_ROOT / "scripts" / "start-manager.sh").read_text(encoding="utf-8")

    assert "openssl rand -hex 24" in text
    assert "tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48" not in text
