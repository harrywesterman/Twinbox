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
    assert 'Usage: install-management-tools.sh [--env-file /path/to/.env]' in text
    assert 'PINNED_KUBECTL_VERSION' in text
    assert 'PINNED_HELM_VERSION' in text
    assert 'talos_output="$(/usr/local/bin/talosctl version --client 2>&1)" || fail "talosctl version check failed: ${talos_output}"' in text
    assert 'tofu_output="$(/usr/local/bin/tofu version 2>&1)" || fail "tofu version check failed: ${tofu_output}"' in text
    assert 'kubectl_output="$(/usr/local/bin/kubectl version --client --output=yaml 2>&1)" || fail "kubectl version check failed: ${kubectl_output}"' in text
    assert 'helm_output="$(/usr/local/bin/helm version --short 2>&1)" || fail "helm version check failed: ${helm_output}"' in text
    assert 'k9s_output="$(/usr/local/bin/k9s version --short 2>&1)" || fail "k9s version check failed: ${k9s_output}"' in text
    assert 'install_wrappers()' in text
    assert 'install -m 0755 "$kubectl_wrapper" /usr/local/bin/k' in text
    assert 'install -m 0755 "$talosctl_wrapper" /usr/local/bin/t' in text


def test_install_management_tools_installs_core_cli_stack_without_bw():
    text = _script_text()
    assert "ensure_openssl()" in text
    assert 'apt-get install -y openssl >/dev/null' in text
    assert "install_argocd()" in text
    assert 'PINNED_ARGOCD_VERSION' in text
    assert 'argocd_output="$(/usr/local/bin/argocd version --client --short 2>&1)"' in text
    assert 'cli_checksums.txt' in text
    assert 'install -m 0755 "$bin_path" /usr/local/bin/argocd' in text
    assert 'configure_argocd_cli()' in text
    assert 'ARGOCD_SERVER' in text
    assert 'export ARGOCD_OPTS="${argocd_opts}"' in text
    assert "install_k9s()" in text
    assert 'PINNED_K9S_VERSION' in text
    assert 'k9s version --short' in text
    assert 'install_talosctl' in text
    assert 'install_tofu' in text
    assert 'install_k9s' in text
    assert 'install_kubectl' in text
    assert 'install_helm' in text
    assert 'install_bw' not in text
