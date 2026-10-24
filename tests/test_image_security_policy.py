import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

from check_node_runtime import declared_version, validate_version  # noqa: E402
from image_matrix import IMAGE_SPECS, image_catalog, workflow_outputs  # noqa: E402
from published_image_issue import decide_issue, load_findings, render_body  # noqa: E402


def test_cve_pins_are_full_patched_versions_in_both_build_and_runtime_stages():
    expected = {
        "manager-api/Dockerfile": "24.22.1",
        "manager-worker/Dockerfile": "26.12.1",
        "manager-web/Dockerfile": "24.22.1",
        "portal/Dockerfile": "24.22.1",
        "twinbox-agents/Dockerfile": "26.12.1",
    }
    for path, version in expected.items():
        text = (ROOT / path).read_text(encoding="utf-8")
        assert f"FROM node:{version}-alpine" in text
        assert declared_version(ROOT / path) == tuple(map(int, version.split(".")))
    assert declared_version(ROOT / "gitops/platform-apps/headwind-mdm/values.yaml") == (24, 22, 1)
    assert "FROM nginx:" in (ROOT / "manager-web/Dockerfile").read_text(encoding="utf-8")


def test_runtime_version_check_rejects_old_or_different_image():
    validate_version((24, 22, 1), "v24.22.1\n")
    validate_version((26, 12, 1), "v26.12.1\n")
    with pytest.raises(ValueError, match="vulnerable"):
        validate_version((24, 22, 0), "v24.22.0")
    with pytest.raises(ValueError, match="differs"):
        validate_version((24, 22, 1), "v24.22.0")
    with pytest.raises(ValueError, match="Unsupported"):
        validate_version((25, 9, 0), "v25.9.0")


def test_shared_image_catalog_selects_changed_images_and_all_published_images():
    names = [image["image_name"] for image in image_catalog("a" * 40)]
    assert len(names) == len(set(names)) == 7
    assert len(IMAGE_SPECS) == 7
    assert image_catalog("a" * 40)[3]["published_ref"].endswith("twinbox-portal:latest")
    outputs = workflow_outputs("a" * 40, "pull_request", "refs/pull/1/merge", {"portal": True})
    assert [item["image_name"] for item in json.loads(outputs["verify_matrix"])["include"]] == [
        "twinbox-portal"
    ]
    assert outputs["should_publish"] == "true"
    outputs = workflow_outputs(
        "a" * 40,
        "pull_request",
        "refs/pull/2/merge",
        {"manager_api": True, "manager_worker": True},
    )
    assert [item["image_name"] for item in json.loads(outputs["verify_matrix"])["include"]] == [
        "twinbox-manager-api",
        "twinbox-manager-worker",
    ]
    filters = (ROOT / ".github/image-build-filters.yml").read_text(encoding="utf-8")
    manager_api_filter = filters.split("manager_api:", 1)[1].split("manager_worker:", 1)[0]
    assert "'config/**'" in manager_api_filter
    outputs = workflow_outputs("a" * 40, "push", "refs/heads/main", {})
    assert len(json.loads(outputs["matrix"])["include"]) == 7
    outputs = workflow_outputs(
        "a" * 40, "pull_request", "refs/pull/1/merge", {"headwind_node": True}
    )
    assert [item["image_name"] for item in json.loads(outputs["verify_matrix"])["include"]] == [
        "headwind-bootstrap-node"
    ]


def test_image_filter_keys_and_workflows_use_shared_selection():
    filters = (ROOT / ".github/image-build-filters.yml").read_text(encoding="utf-8")
    for key, *_ in IMAGE_SPECS:
        assert f"{key}:" in filters
    publish = (ROOT / ".github/workflows/docker-publish.yml").read_text(encoding="utf-8")
    verify = (ROOT / ".github/workflows/verify.yml").read_text(encoding="utf-8")
    for workflow in (publish, verify):
        assert "filters: .github/image-build-filters.yml" in workflow
        assert "python3 scripts/ci/image_matrix.py" in workflow
        assert "ignore-unfixed: true" in workflow
        assert "exit-code: '1'" in workflow
    assert "needs: [changes, tests, image-scan]" in verify


def test_scheduled_issue_is_deduplicated_and_scan_failure_cannot_close_it(tmp_path):
    names = [item["image_name"] for item in image_catalog("a" * 40)]
    for name in names:
        folder = tmp_path / name
        folder.mkdir()
        (folder / "digest.txt").write_text(f"ghcr.io/example/{name}@sha256:{'a' * 64}\n")
        (folder / "report.json").write_text(json.dumps({"Results": []}))
    findings = load_findings(tmp_path, names)
    assert decide_issue(None, findings) == "none"
    existing = {"state": "OPEN", "body": "old"}
    assert decide_issue(existing, findings) == "close"
    report_path = tmp_path / names[0] / "report.json"
    report_path.write_text(
        json.dumps(
            {
                "Results": [
                    {
                        "Vulnerabilities": [
                            {
                                "VulnerabilityID": "CVE-2026-111497",
                                "PkgName": "node",
                                "InstalledVersion": "24.22.0",
                                "FixedVersion": "24.22.1",
                                "Severity": "CRITICAL",
                            }
                        ]
                    }
                ]
            }
        )
    )
    findings = load_findings(tmp_path, names)
    assert decide_issue(None, findings) == "create"
    assert decide_issue(existing, findings) == "update"
    assert decide_issue({"state": "OPEN", "body": render_body(findings)}, findings) == "none"
    assert decide_issue({"state": "CLOSED", "body": ""}, findings) == "reopen"
    changed = json.loads(json.dumps(findings))
    changed[0]["vulnerabilities"][0]["fixed"] = "24.22.2"
    assert render_body(changed) != render_body(findings)
    report_path.unlink()
    with pytest.raises(FileNotFoundError):
        load_findings(tmp_path, names)
    monitor = (ROOT / ".github/workflows/image-vulnerability-monitor.yml").read_text(
        encoding="utf-8"
    )
    assert "if: needs.scan.result == 'success'" in monitor
    assert "issues: write" in monitor
