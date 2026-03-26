from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "bootstrap-vaultwarden.sh"


def _script_text() -> str:
    assert SCRIPT_PATH.exists(), "bootstrap-vaultwarden.sh must exist for the Vaultwarden bootstrap flow"
    return SCRIPT_PATH.read_text(encoding="utf-8")


def test_bootstrap_vaultwarden_script_has_check_only_mode_and_shell_safety():
    text = _script_text()

    assert "set -euo pipefail" in text
    assert "--check-only" in text
    assert "VAULTWARDEN_READY_FILE" in text
    assert "http://127.0.0.1:8222" in text or "${VAULTWARDEN_LOCAL_PORT:-8222}" in text
    assert "curl -fsS" in text
    assert 'bw login "$VAULTWARDEN_VAULT_EMAIL" --passwordfile "$VAULTWARDEN_PASSWORD_FILE"' in text
    assert 'bw login "$VAULTWARDEN_VAULT_EMAIL" "$' not in text


def test_bootstrap_vaultwarden_script_bootstraps_registration_and_api_key_headlessly():
    text = _script_text()

    assert "VAULTWARDEN_CLIENTID_FILE" in text
    assert "VAULTWARDEN_CLIENTSECRET_FILE" in text
    assert ".apiKey // .ApiKey // empty" in text
    assert "bw login --apikey" in text
    assert "bw unlock --passwordfile" in text
    assert "/identity/accounts/register/send-verification-email" in text
    assert "/identity/accounts/register/finish" in text
    assert "/api/accounts/api-key" in text
    assert "twinbox/global/proxmox" in text
    assert "seed" in text.lower()
    assert "vaultwarden-ready" in text


def test_bootstrap_vaultwarden_script_disables_signups_and_restarts_vaultwarden():
    text = _script_text()

    assert "VAULTWARDEN_SIGNUPS_ALLOWED=false" in text
    assert "docker compose up -d vaultwarden" in text
    assert "VAULTWARDEN_PASSWORD_FILE" in text
    assert "disable_signups\n  restart_vaultwarden\n  write_ready_file" in text
