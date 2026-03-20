from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_docker_compose_mounts_categories_and_host_cron_contract():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")

    assert "WORKSPACE_ROOT=/opt/twinbox" in text
    assert "./categories:/opt/twinbox/categories:ro" in text
    assert "TWINBOX_HOST_REPO_ROOT=${TWINBOX_HOST_REPO_ROOT}" in text
    assert "/etc/cron.d:/host/etc/cron.d" in text


def test_env_example_includes_host_repo_root():
    text = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")

    assert "TWINBOX_HOST_REPO_ROOT=" in text


def test_bootstrap_vm_sets_host_repo_root_when_missing():
    text = (REPO_ROOT / "scripts" / "bootstrap-vm.sh").read_text(encoding="utf-8")

    assert 'if ! grep -q "^TWINBOX_HOST_REPO_ROOT=" .env; then' in text
    assert 'printf \'\\nTWINBOX_HOST_REPO_ROOT=%s\\n\' "$TARGET_DIR" >> .env' in text
