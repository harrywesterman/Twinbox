import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANAGER_API_TRUSTED_CIDRS = "127.0.0.1/32,::1/128,172.16.0.0/12,10.0.0.0/8"


def test_docker_compose_mounts_categories_and_host_cron_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    api_block = text.split("  manager-api:", 1)[1].split("\n  manager-worker:", 1)[0]
    worker_block = text.split("  manager-worker:", 1)[1].split("\n  manager-web:", 1)[0]

    assert "WORKSPACE_ROOT=/opt/twinbox" in text
    assert "MANAGER_API_TRUSTED_CIDRS=${MANAGER_API_TRUSTED_CIDRS:-" in text
    assert (
        "TWINBOX_GIT_REPO_URL=${TWINBOX_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
        in worker_block
    )
    assert "TWINBOX_GIT_TARGET_REVISION=${TWINBOX_GIT_TARGET_REVISION:-main}" in worker_block
    assert "TWINBOX_HOST_RUNTIME_DIR=${TWINBOX_HOST_RUNTIME_DIR:-/host/opt/twinbox}" in worker_block
    assert "TWINBOX_GIT_REPO_URL=" not in api_block
    assert "TWINBOX_GIT_TARGET_REVISION=" not in api_block
    assert "TWINBOX_SYNC_LOCAL_CLIENT_CONFIGS=true" in text
    assert "/opt/twinbox/manager-data:/data" in text
    assert "TWINBOX_HOST_REPO_ROOT=${TWINBOX_HOST_REPO_ROOT}" in text
    assert "/etc/cron.d:/host/etc/cron.d" in text
    assert "/opt/twinbox:/host/opt/twinbox" in worker_block
    assert "/var/run/docker.sock:/var/run/docker.sock" in text


def test_docker_compose_uses_flat_forgejo_root_url_interpolation():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "FORGEJO__server__ROOT_URL=${FORGEJO_ROOT_URL:-http://localhost:3001/}" in text
    assert "FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION=true" in text
    assert re.search(r"FORGEJO__server__ROOT_URL=.*\$\{[^}\n]*\$\{", text) is None


def test_docker_compose_exposes_filesystem_secret_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "TWINBOX_SECRET_BACKEND=${TWINBOX_SECRET_BACKEND:-filesystem}" in text
    assert "TWINBOX_BOOTSTRAP_DIR=${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}" in text
    assert "TWINBOX_SECRET_ITEM_PREFIX=${TWINBOX_SECRET_ITEM_PREFIX:-twinbox}" in text
    assert "container_name: twinbox-seaweedfs-admin" in text
    assert "- admin" in text
    assert "- -masters=seaweedfs:9333" in text
    assert "- -port=23646" in text
    assert "- -volume.max=0" in text
    assert text.count('"23646:23646"') == 1
    seaweedfs_images = re.findall(r"image: chrislusf/seaweedfs:([0-9.]+)", text)
    assert seaweedfs_images
    assert set(seaweedfs_images) == {seaweedfs_images[0]}
    assert "vaultwarden" not in text
    assert "bitwarden" not in text


def test_docker_compose_beszel_has_safe_app_url_fallback():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "APP_URL=${BESZEL_APP_URL:-http://127.0.0.1:8090}" in text
    assert "APP_URL=${BESZEL_APP_URL:-}" not in text


def test_env_example_includes_filesystem_bootstrap_contract():
    text = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")

    assert "TWINBOX_HOST_REPO_ROOT=" in text
    assert f"MANAGER_API_TRUSTED_CIDRS={MANAGER_API_TRUSTED_CIDRS}" in text
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


def test_start_manager_configures_manager_api_source_allowlist_firewall():
    text = (REPO_ROOT / "scripts" / "start-manager.sh").read_text(encoding="utf-8")

    assert "append_manager_api_source_allowlist" in text
    assert f"MANAGER_API_TRUSTED_CIDRS={MANAGER_API_TRUSTED_CIDRS}" in text
    assert "configure-manager-api-firewall.sh" in text
    assert 'sudo "${BOOTSTRAP_DIR}/bin/configure-manager-api-firewall.sh"' in text
    assert "sync-manager-api-node-allowlist.sh" in text


def test_start_manager_bootstraps_forgejo_before_full_stack():
    text = (REPO_ROOT / "scripts" / "start-manager.sh").read_text(encoding="utf-8")

    assert "append_forgejo_env_block" in text
    assert 'append_env_value_if_missing "FORGEJO_HTTP_PORT"' in text
    assert 'append_env_value_if_missing "FORGEJO_ROOT_URL"' in text
    assert 'append_env_value_if_missing "TWINBOX_FORGEJO_REPO_URL"' in text
    assert "runtime_services=(" in text
    assert "docker compose pull forgejo" in text
    assert "docker compose up -d forgejo" in text
    assert '"${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh"' in text
    assert 'docker compose pull "${runtime_services[@]}"' in text
    assert 'docker compose up -d "${runtime_services[@]}"' in text

    append_pos = text.index("\nappend_forgejo_env_block\n")
    forgejo_pull_pos = text.index("docker compose pull forgejo")
    forgejo_up_pos = text.index("docker compose up -d forgejo")
    bootstrap_pos = text.index(
        'if [[ "$forgejo_started" == "true" && -x "${BOOTSTRAP_DIR}/bin/bootstrap-forgejo.sh" ]]'
    )
    runtime_pull_pos = text.index('docker compose pull "${runtime_services[@]}"')
    runtime_up_pos = text.index('docker compose up -d "${runtime_services[@]}"')

    assert (
        append_pos
        < forgejo_pull_pos
        < forgejo_up_pos
        < bootstrap_pos
        < runtime_pull_pos
        < runtime_up_pos
    )


def test_manager_api_firewall_limits_docker_published_port():
    text = (REPO_ROOT / "scripts" / "manager" / "configure-manager-api-firewall.sh").read_text(
        encoding="utf-8"
    )

    assert 'MANAGER_API_PORT="${MANAGER_API_PORT:-8080}"' in text
    assert 'MANAGER_API_TRUSTED_CIDRS="${MANAGER_API_TRUSTED_CIDRS:-' in text
    assert MANAGER_API_TRUSTED_CIDRS in text
    assert 'ufw insert 1 allow from "$cidr" to any port "$MANAGER_API_PORT" proto tcp' in text
    assert 'ufw deny in to any port "$MANAGER_API_PORT" proto tcp' in text
    assert "DOCKER-USER" in text
    assert 'iptables -A "$CHAIN" -p tcp --dport "$MANAGER_API_PORT" -s "$cidr" -j RETURN' in text
    assert 'iptables -A "$CHAIN" -p tcp --dport "$MANAGER_API_PORT" -j DROP' in text
    assert "192.168.0.0/16" not in text
