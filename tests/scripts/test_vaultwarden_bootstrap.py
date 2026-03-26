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
    assert "VAULTWARDEN_PUBLIC_URL" in text
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
    assert 'item_name="${VAULTWARDEN_ITEM_PREFIX:-twinbox}/global/proxmox"' in text
    assert 'item_name="${VAULTWARDEN_ITEM_PREFIX:-twinbox}/global/grafana"' in text
    assert "seed" in text.lower()
    assert "vaultwarden-ready" in text


def test_bootstrap_vaultwarden_script_disables_signups_and_restarts_vaultwarden():
    text = _script_text()

    assert "VAULTWARDEN_SIGNUPS_ALLOWED=false" in text
    assert "docker compose up -d vaultwarden" in text
    assert "VAULTWARDEN_PASSWORD_FILE" in text
    assert "disable_signups\n  restart_vaultwarden\n  write_ready_file" in text


def test_bootstrap_vaultwarden_script_syncs_before_api_key_generation():
    text = _script_text()
    bootstrap_section = text.split("ensure_local_account_bootstrap() {", 1)[1].split("ensure_vaultwarden_login() {", 1)[0]

    assert 'bootstrap_session="$(unlock_session)"' in bootstrap_section
    assert 'bw sync --session "$bootstrap_session" >/dev/null' in bootstrap_section
    assert bootstrap_section.index('bw sync --session "$bootstrap_session" >/dev/null') < bootstrap_section.index(
        'create_personal_api_key_files'
    )


def test_bootstrap_vaultwarden_script_requires_seeded_proxmox_item_before_ready_shortcut():
    text = _script_text()
    probe_section = text.split("probe_vaultwarden_access() {", 1)[1].split("password_login() {", 1)[0]
    seed_section = text.split("seed_proxmox_item() {", 1)[1].split("disable_signups() {", 1)[0]
    grafana_seed_section = text.split("seed_grafana_item() {", 1)[1].split("disable_signups() {", 1)[0]

    assert 'item_name="${VAULTWARDEN_ITEM_PREFIX:-twinbox}/global/proxmox"' in probe_section
    assert 'bw list items --session "$session" --search "$item_name"' in probe_section
    assert 'jq -e --arg name "$item_name" \'.[] | select(.name == $name)\'' in probe_section
    assert 'item_name="${VAULTWARDEN_ITEM_PREFIX:-twinbox}/global/proxmox"' in seed_section
    assert 'item_name="${VAULTWARDEN_ITEM_PREFIX:-twinbox}/global/grafana"' in grafana_seed_section
    assert 'grafana_password="$(openssl rand -hex 16)"' in grafana_seed_section


def test_bootstrap_vaultwarden_script_parses_multiline_bitwarden_context():
    text = _script_text()
    create_section = text.split("create_personal_api_key_files() {", 1)[1].split("ensure_local_account_bootstrap() {", 1)[0]

    assert 'mapfile -t bw_context_lines <<< "$bw_context"' in create_section
    assert 'user_id="${bw_context_lines[0]:-}"' in create_section
    assert 'access_token="${bw_context_lines[1]:-}"' in create_section
    assert 'kdf_type="${bw_context_lines[2]:-}"' in create_section
    assert 'kdf_iterations="${bw_context_lines[3]:-}"' in create_section


def test_bootstrap_vaultwarden_script_normalizes_bootstrap_directory_ownership():
    text = _script_text()

    assert "BOOTSTRAP_OWNER" in text
    assert "ensure_bootstrap_ownership()" in text
    assert 'chown -R "${BOOTSTRAP_OWNER}:${BOOTSTRAP_OWNER}" "$bootstrap_root"' in text
    assert "ensure_bootstrap_ownership" in text
