import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RENOVATE_CONFIG = REPO_ROOT / "renovate.json"
DEPENDABOT_CONFIG = REPO_ROOT / ".github" / "dependabot.yml"
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


def _config() -> dict:
    return json.loads(RENOVATE_CONFIG.read_text(encoding="utf-8"))


def _rule(config: dict, description: str) -> dict:
    matches = [rule for rule in config["packageRules"] if rule.get("description") == description]
    assert len(matches) == 1, f"expected one package rule named {description!r}"
    return matches[0]


def test_renovate_uses_pr_automerge_behind_the_required_check():
    config = _config()

    assert config["timezone"] == "Europe/Amsterdam"
    assert config["automergeType"] == "pr"
    assert config["automergeStrategy"] == "squash"
    assert config["platformAutomerge"] is True
    assert config["ignoreTests"] is False
    assert config["rebaseWhen"] == "behind-base-branch"
    assert config["prConcurrentLimit"] == 4


def test_only_stable_npm_development_updates_are_automerged_daily():
    config = _config()
    rule = _rule(config, "Automerge stable npm development updates")

    assert rule["matchManagers"] == ["npm"]
    assert rule["matchDepTypes"] == ["devDependencies"]
    assert set(rule["matchUpdateTypes"]) == {"minor", "patch"}
    assert rule["matchCurrentVersion"] == "!/^0/"
    assert rule["minimumReleaseAge"] == "14 days"
    assert rule["internalChecksFilter"] == "strict"
    assert rule["schedule"] == ["before 06:00 every weekday"]
    assert rule["automerge"] is True


def test_only_root_tooling_lockfile_maintenance_is_automerged():
    config = _config()
    root_rule = _rule(config, "Automerge root tooling lock file maintenance")
    nested_rule = _rule(config, "Keep runtime lock file maintenance manual")

    assert config["lockFileMaintenance"]["enabled"] is True
    assert root_rule["matchUpdateTypes"] == ["lockFileMaintenance"]
    assert root_rule["matchFileNames"] == ["package-lock.json"]
    assert root_rule["groupName"] == "Root tooling lock file maintenance"
    assert root_rule["automerge"] is True
    assert nested_rule["matchUpdateTypes"] == ["lockFileMaintenance"]
    assert nested_rule["matchFileNames"] == ["**/package-lock.json", "!package-lock.json"]
    assert nested_rule["automerge"] is False


def test_only_verify_workflow_digest_updates_are_automerged():
    config = _config()
    rule = _rule(config, "Automerge Verify workflow action digests")

    assert "helpers:pinGitHubActionDigests" in config["extends"]
    assert rule["matchManagers"] == ["github-actions"]
    assert rule["matchUpdateTypes"] == ["digest"]
    assert rule["matchFileNames"] == [".github/workflows/verify.yml"]
    assert rule["automerge"] is True


def test_no_other_package_rule_enables_automerge():
    config = _config()
    allowed = {
        "Automerge stable npm development updates",
        "Automerge root tooling lock file maintenance",
        "Automerge Verify workflow action digests",
    }

    enabled = {
        rule.get("description") for rule in config["packageRules"] if rule.get("automerge") is True
    }
    assert enabled == allowed


def test_security_updates_are_immediate_and_assigned():
    alerts = _config()["vulnerabilityAlerts"]

    assert alerts["enabled"] is True
    assert alerts["addLabels"] == ["security"]
    assert alerts["assignees"] == ["harrywesterman"]
    assert alerts["schedule"] == []
    assert alerts["minimumReleaseAge"] is None


def test_dependabot_version_updates_are_disabled():
    assert not DEPENDABOT_CONFIG.exists()


def test_only_publish_workflow_can_write_repository_contents():
    writers = []
    for workflow in WORKFLOWS_DIR.glob("*.yml"):
        text = workflow.read_text(encoding="utf-8")
        if re.search(r"^\s+contents:\s+write\s*$", text, flags=re.MULTILINE):
            writers.append(workflow.name)

    assert writers == ["docker-publish.yml"]


def test_image_reference_push_uses_the_dedicated_deploy_key():
    workflow = (WORKFLOWS_DIR / "docker-publish.yml").read_text(encoding="utf-8")
    update_refs = workflow.split("  update-refs:", maxsplit=1)[1]

    assert "ssh-key: ${{ secrets.TWINBOX_IMAGE_REFS_DEPLOY_KEY }}" in update_refs
    assert "token: ${{ secrets.GITHUB_TOKEN }}" not in update_refs
