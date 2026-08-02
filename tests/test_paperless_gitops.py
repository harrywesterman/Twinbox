"""Regression tests for the Paperless deployment manifest."""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_paperless_disables_service_links_to_protect_paperless_port_settings():
    manifest = yaml.safe_load(
        (REPO_ROOT / "gitops" / "platform-apps" / "paperless" / "deployment.yaml").read_text(
            encoding="utf-8"
        )
    )

    assert manifest["spec"]["template"]["spec"]["enableServiceLinks"] is False


def test_paperless_syncs_authentik_admin_group():
    manifest = yaml.safe_load(
        (REPO_ROOT / "gitops" / "platform-apps" / "paperless" / "deployment.yaml").read_text(
            encoding="utf-8"
        )
    )
    env = {
        item["name"]: item["value"]
        for item in manifest["spec"]["template"]["spec"]["containers"][0]["env"]
    }

    assert env["PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS"] == "true"
    assert env["PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM"] == "groups"


def test_paperless_install_exposes_and_provisions_authentik_admins_group():
    script = (
        REPO_ROOT / "categories" / "apps" / "steps" / "install-paperless" / "run.sh"
    ).read_text(encoding="utf-8")

    assert '"paperless-groups"' in script
    assert 'ak_is_group_member(request.user, name="admins")' in script
    assert 'SCOPE: ["openid", "profile", "email", "groups"]' in script
    assert 'Group.objects.get_or_create(name="admins")' in script
    assert "group.permissions.set(Permission.objects.all())" in script
