from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
IMMICH_APP_STEP = REPO_ROOT / "categories" / "apps" / "steps" / "install-immich" / "step.yaml"
IMMICH_RUN = REPO_ROOT / "categories" / "apps" / "steps" / "install-immich" / "run.sh"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_install_immich_step_is_backed_by_a_real_runner():
    app_step_text = _read(IMMICH_APP_STEP)
    assert "Placeholder step" not in app_step_text
    assert "categories/apps/steps/install-immich/run.sh" in app_step_text
    assert "url_template: https://immich.__ZONE_NAME__" in app_step_text
    assert "item: kubeconfig" in app_step_text


def test_install_immich_runner_binds_allow_all_authenticated_policy_for_all_users():
    run_text = _read(IMMICH_RUN)

    assert 'source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"' in run_text
    assert "ensure_group_binding()" in run_text
    assert "ensure_policy_binding()" in run_text
    assert "find_or_create_allow_all_policy()" in run_text
    assert 'authentik_api_get "/policies/expression/?page_size=200"' in run_text
    assert 'authentik_api_write POST "/policies/expression/"' in run_text
    assert (
        '"name":"allow-all-authenticated","execution_logging":false,"expression":"return True"'
        in run_text
    )
    assert "{target: $target_uuid, policy: $policy_id, order: 0, enabled: true}" in run_text
    assert (
        'ensure_policy_binding "$application_uuid" "$(find_or_create_allow_all_policy)"' in run_text
    )
    assert 'ensure_group_binding "$application_uuid" "$admins_group_id"' in run_text
    assert "Provisioning Authentik OIDC client for Immich" in run_text
