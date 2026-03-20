from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "install-management-tools.sh"


def _script_text() -> str:
    return SCRIPT_PATH.read_text(encoding="utf-8")


def test_install_management_tools_checks_x86_64_v2_flags_for_recent_talosctl():
    text = _script_text()
    assert 'source "$SCRIPT_DIR/../config/pinned-defaults.sh"' in text
    assert "ensure_talos_cpu_compatibility()" in text
    assert 'if ! version_gte "$talos_version" "1.7.0"; then' in text
    assert "required_flags=(ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm)" in text
    assert "set VM CPU type to 'host' (or x86-64-v2-AES)" in text


def test_install_management_tools_fails_on_version_command_errors():
    text = _script_text()
    assert 'required_vars=(KUBECTL_VERSION HELM_VERSION)' in text
    assert "TALOSCTL_VERSION" not in text.split("required_vars=", 1)[1].split("for var in", 1)[0]
    assert 'talos_output="$(/usr/local/bin/talosctl version --client 2>&1)" || fail "talosctl version check failed: ${talos_output}"' in text
    assert 'tofu_output="$(/usr/local/bin/tofu version 2>&1)" || fail "tofu version check failed: ${tofu_output}"' in text
    assert 'kubectl_output="$(/usr/local/bin/kubectl version --client --output=yaml 2>&1)" || fail "kubectl version check failed: ${kubectl_output}"' in text
    assert 'helm_output="$(/usr/local/bin/helm version --short 2>&1)" || fail "helm version check failed: ${helm_output}"' in text
