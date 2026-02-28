from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WIZARD_PATH = REPO_ROOT / "wizard" / "setup-wizard.sh"


def _wizard_text() -> str:
    return WIZARD_PATH.read_text(encoding="utf-8")


def test_setup_wizard_registers_exit_cleanup_trap():
    text = _wizard_text()
    assert "trap cleanup_after_run EXIT" in text


def test_setup_wizard_cleanup_removes_snippet_on_error():
    text = _wizard_text()
    assert '[[ -n "${snippet_file:-}" && -f "$snippet_file" ]]' in text
    assert 'rm -f "$snippet_file"' in text


def test_setup_wizard_cleanup_rolls_back_created_vm_on_error():
    text = _wizard_text()
    assert '[[ "${vm_created:-0}" -eq 1 ]]' in text
    assert 'qm stop "$MGT_ID" --skiplock 1 >/dev/null 2>&1 || true' in text
    assert 'qm destroy "$MGT_ID" --purge 1 >/dev/null 2>&1 || true' in text
