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
    assert config["prConcurrentLimit"] == 12
    assert config["prHourlyLimit"] == 2
    assert config["branchConcurrentLimit"] == 16


def test_platform_image_detection_covers_named_workloads_and_init_containers():
    config = _config()
    manager = next(
        m
        for m in config["customManagers"]
        if m.get("description") == "Image tags in all GitOps platform manifests"
    )
    patterns = [re.compile(p[1:-1]) for p in manager["managerFilePatterns"]]
    image_pattern = re.compile(manager["matchStrings"][0].replace("(?<", "(?P<"))
    expected = {
        "nats-deployment.yaml": "nats",
        "coturn-deployment.yaml": "coturn/coturn",
        "signaling-deployment.yaml": "strukturag/nextcloud-spreed-signaling",
        "recording-deployment.yaml": "ghcr.io/nextcloud-releases/aio-talk-recording",
        "eurooffice-deployment.yaml": "ghcr.io/euro-office/documentserver",
    }
    for filename, image in expected.items():
        path = f"gitops/platform-apps/nextcloud/{filename}"
        assert any(p.search(path) for p in patterns), path
        matches = list(image_pattern.finditer((REPO_ROOT / path).read_text()))
        assert image in {m["depName"] for m in matches}, path
    assert not any(p.search("manager-data/generated/deployment.yaml") for p in patterns)


def test_only_stable_npm_development_updates_are_automerged():
    config = _config()
    rule = _rule(config, "Automerge stable npm development updates")

    assert rule["matchManagers"] == ["npm"]
    assert rule["matchDepTypes"] == ["devDependencies"]
    assert set(rule["matchUpdateTypes"]) == {"minor", "patch"}
    assert rule["matchCurrentVersion"] == "!/^0/"
    assert rule["minimumReleaseAge"] == "14 days"
    assert rule["internalChecksFilter"] == "strict"
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


def test_read_only_workflow_digest_updates_are_automerged():
    config = _config()
    rule = _rule(config, "Automerge read-only workflow action digests")

    assert "helpers:pinGitHubActionDigests" in config["extends"]
    assert rule["matchManagers"] == ["github-actions"]
    assert rule["matchUpdateTypes"] == ["digest"]
    assert set(rule["matchFileNames"]) == {
        ".github/workflows/verify.yml",
        ".github/workflows/deploy-pages.yml",
    }
    assert ".github/workflows/docker-publish.yml" not in rule["matchFileNames"]
    assert rule["automerge"] is True


def test_unsafe_forgejo_release_is_excluded_without_blocking_later_versions():
    config = _config()
    rule = _rule(config, "Skip Forgejo 17.0.0 while upstream advises against upgrading")

    assert rule["matchDatasources"] == ["docker"]
    assert rule["matchPackageNames"] == ["forgejo/forgejo"]
    pattern = rule["allowedVersions"]
    assert pattern.startswith("!/") and pattern.endswith("/")
    excluded = re.compile(pattern[2:-1])
    assert excluded.fullmatch("17.0.0")
    assert excluded.fullmatch("v17.0.0")
    assert not excluded.fullmatch("17.0.1")


def test_no_other_package_rule_enables_automerge():
    config = _config()
    allowed = {
        "Automerge Helm chart and container image non-major updates with timestamp-tolerant release-age checks",
        "Automerge patched Node image releases after one day",
        "Automerge stable npm development updates",
        "Automerge stable npm runtime updates",
        "Automerge root tooling lock file maintenance",
        "Automerge read-only workflow action digests",
    }

    enabled = {
        rule.get("description") for rule in config["packageRules"] if rule.get("automerge") is True
    }
    assert enabled == allowed


def test_security_updates_are_automergeable_after_a_short_soak():
    config = _config()
    alerts = config["vulnerabilityAlerts"]

    assert alerts["enabled"] is True
    assert alerts["addLabels"] == ["security"]
    assert alerts["assignees"] == ["harrywesterman"]
    assert alerts["schedule"] == []
    assert alerts["minimumReleaseAge"] == "3 days"
    assert alerts["internalChecksFilter"] == "strict"
    assert alerts["automerge"] is True
    assert config["osvVulnerabilityAlerts"] is True


def test_node_image_patch_updates_have_one_day_wait_without_major_automerge():
    rule = _rule(_config(), "Automerge patched Node image releases after one day")
    assert rule["matchDatasources"] == ["docker"]
    assert rule["matchPackageNames"] == ["node"]
    assert rule["matchUpdateTypes"] == ["patch"]
    assert rule["minimumReleaseAge"] == "1 day"
    assert rule["internalChecksFilter"] == "strict"
    assert rule["automerge"] is True


def test_updates_run_at_any_time_without_a_schedule_window():
    config = _config()

    scheduled = [rule for rule in config["packageRules"] if "schedule" in rule]
    assert scheduled == []


def test_helm_and_image_updates_automerge_non_major():
    config = _config()
    rule = _rule(
        config,
        "Automerge Helm chart and container image non-major updates with timestamp-tolerant release-age checks",
    )

    assert set(rule["matchDatasources"]) == {"helm", "docker"}
    assert set(rule["matchUpdateTypes"]) == {"minor", "patch", "digest"}
    assert rule["matchCurrentVersion"] == "!/^0/"
    assert rule["minimumReleaseAge"] == "7 days"
    assert rule["minimumReleaseAgeBehaviour"] == "timestamp-optional"
    assert rule["internalChecksFilter"] == "strict"
    assert rule["automerge"] is True
    assert "major" not in rule["matchUpdateTypes"]


def test_npm_runtime_updates_automerge_non_major():
    config = _config()
    rule = _rule(config, "Automerge stable npm runtime updates")

    assert rule["matchManagers"] == ["npm"]
    assert rule["matchDepTypes"] == ["dependencies"]
    assert set(rule["matchUpdateTypes"]) == {"minor", "patch"}
    assert rule["matchCurrentVersion"] == "!/^0/"
    assert rule["minimumReleaseAge"] == "14 days"
    assert rule["internalChecksFilter"] == "strict"
    assert rule["automerge"] is True


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


def test_image_reference_push_skips_stale_runs_and_retries_concurrent_updates():
    workflow = (WORKFLOWS_DIR / "docker-publish.yml").read_text(encoding="utf-8")
    commit_step = workflow.split("      - name: Commit and push if changed", maxsplit=1)[1]

    assert "git fetch origin main" in commit_step
    assert "git rev-parse origin/main" in commit_step
    assert '"$GITHUB_SHA"' in commit_step
    assert "for attempt in 1 2 3" in commit_step
    assert "main moved during the push" in commit_step
