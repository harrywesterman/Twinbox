from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_docker_compose_mounts_categories_and_host_cron_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    assert "WORKSPACE_ROOT=/opt/twinbox" in text
    assert "TWINBOX_SYNC_LOCAL_CLIENT_CONFIGS=true" in text
    assert "/opt/twinbox/manager-data:/data" in text
    assert "TWINBOX_HOST_REPO_ROOT=${TWINBOX_HOST_REPO_ROOT}" in text
    assert "/etc/cron.d:/host/etc/cron.d" in text


def test_docker_compose_exposes_filesystem_secret_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "TWINBOX_SECRET_BACKEND=${TWINBOX_SECRET_BACKEND:-filesystem}" in text
    assert "TWINBOX_BOOTSTRAP_DIR=${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}" in text
    assert "TWINBOX_SECRET_ITEM_PREFIX=${TWINBOX_SECRET_ITEM_PREFIX:-twinbox}" in text
    assert "container_name: twinbox-seaweedfs-admin" in text
    assert "- admin" in text
    assert "- -masters=seaweedfs:9333" in text
    assert "- -port=23646" in text
    assert text.count('"23646:23646"') == 1
    assert "seaweedfs:\n    image: chrislusf/seaweedfs:4.23" in text
    assert "vaultwarden" not in text
    assert "bitwarden" not in text


def test_env_example_includes_filesystem_bootstrap_contract():
    text = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")

    assert "TWINBOX_HOST_REPO_ROOT=" in text
    assert "TWINBOX_SECRET_BACKEND=filesystem" in text
    assert "TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap" in text
    assert "TWINBOX_SECRET_ITEM_PREFIX=twinbox" in text
    assert "TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets" in text
    assert "TWINBOX_SECRET_CACHE_TTL_SEC=60" in text
    assert "vaultwarden" not in text.lower()
    assert "bitwarden" not in text.lower()


def test_bootstrap_scripts_materialize_filesystem_secret_tree_and_openbao_seal_files():
    start_text = (REPO_ROOT / "scripts" / "start-manager.sh").read_text(encoding="utf-8")
    bootstrap_text = (REPO_ROOT / "scripts" / "bootstrap-vm.sh").read_text(encoding="utf-8")

    for text in (start_text, bootstrap_text):
        assert "TWINBOX_SECRET_BACKEND=filesystem" in text
        assert "TWINBOX_BOOTSTRAP_DIR=/opt/twinbox/bootstrap" in text
        assert "TWINBOX_SECRET_ITEM_PREFIX=twinbox" in text
        assert "TWINBOX_SECRET_TEMP_DIR=/tmp/twinbox-secrets" in text
        assert 'local secret_dir="${BOOTSTRAP_DIR}/secrets/global"' in text
        assert 'local proxmox_file="${secret_dir}/proxmox.json"' in text
        assert 'local traefik_file="${secret_dir}/traefik-dashboard.json"' in text
        assert 'local openbao_seal_dir="${BOOTSTRAP_DIR}/openbao/seal"' in text
        assert 'local seal_key_file="${openbao_seal_dir}/current.key"' in text
        assert 'local seal_key_id_file="${openbao_seal_dir}/current-key-id"' in text
        assert "vaultwarden" not in text.lower()
        assert "bitwarden" not in text.lower()

    assert "openssl passwd -apr1" in start_text
    assert "openssl passwd -apr1" in bootstrap_text
