import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

from image_matrix import image_catalog  # noqa: E402
from published_image_issue import load_assessed_findings  # noqa: E402
from security_report import assess, build_report, read_rules  # noqa: E402


def test_debian_minizip_exception_is_exact_and_expires():
    rules = read_rules(ROOT / "config/security/assessment-rules.json")
    finding = {
        "vulnerabilityId": "CVE-2023-45853",
        "packageName": "zlib1g",
        "installedVersion": "1:1.2.13.dfsg-1",
    }
    bookworm = {"family": "debian", "name": "12.15"}
    assert assess(finding, bookworm, rules)["status"] == "not_affected"
    assert (
        assess({**finding, "packageName": "minizip"}, bookworm, rules)["status"] == "needs_review"
    )
    assert assess(finding, {"family": "debian", "name": "13"}, rules)["status"] == "needs_review"
    assert (
        assess(finding, bookworm, rules, datetime(2026, 12, 1, tzinfo=UTC))["status"]
        == "needs_review"
    )


def test_complete_report_preserves_targets_and_all_severities(tmp_path):
    specs = image_catalog("")
    for spec in specs:
        folder = tmp_path / spec["image_name"]
        folder.mkdir()
        (folder / "digest.txt").write_text(
            f"ghcr.io/example/{spec['image_name']}@sha256:{'a' * 64}"
        )
        (folder / "platform.txt").write_text("linux/amd64")
        (folder / "scanned-at.txt").write_text(datetime.now(UTC).isoformat())
        (folder / "report.json").write_text(
            json.dumps(
                {
                    "ArtifactName": f"ghcr.io/example/{spec['image_name']}@sha256:{'a' * 64}",
                    "Metadata": {"OS": {"Family": "debian", "Name": "12.15"}},
                    "Results": [
                        {
                            "Target": "usr/lib/libz.so",
                            "Type": "debian",
                            "Vulnerabilities": [
                                {
                                    "VulnerabilityID": "CVE-2023-45853",
                                    "PkgName": "zlib1g",
                                    "InstalledVersion": "1:1.2.13.dfsg-1",
                                    "Severity": "CRITICAL",
                                }
                            ],
                        },
                        {
                            "Target": "usr/bin/other",
                            "Type": "gobinary",
                            "Vulnerabilities": [
                                {
                                    "VulnerabilityID": "CVE-2023-45853",
                                    "PkgName": "zlib1g",
                                    "InstalledVersion": "1:1.2.13.dfsg-1",
                                    "Severity": "LOW",
                                }
                            ],
                        },
                    ],
                }
            )
        )
    report = build_report(
        tmp_path,
        run_id="42",
        commit_sha="b" * 40,
        rules_path=ROOT / "config/security/assessment-rules.json",
    )
    assert len(report["images"]) == 7
    assert report["images"][5]["publishedRef"].endswith(
        "twinbox-manager-worker:jitsi-openid-latest"
    )
    findings = report["images"][0]["findings"]
    assert {f["originalSeverity"] for f in findings} == {"CRITICAL", "LOW"}
    assert len({f["id"] for f in findings}) == 2
    assert all(f["status"] == "not_affected" for f in findings)
    report_path = tmp_path / "security-report.json"
    report_path.write_text(json.dumps(report))
    assert all(not item["vulnerabilities"] for item in load_assessed_findings(report_path))
    report["images"][0]["findings"][0]["status"] = "needs_review"
    report_path.write_text(json.dumps(report))
    assert len(load_assessed_findings(report_path)[0]["vulnerabilities"]) == 1
    (tmp_path / specs[1]["image_name"] / "platform.txt").unlink()
    with pytest.raises(FileNotFoundError):
        build_report(
            tmp_path,
            run_id="43",
            commit_sha="c" * 40,
            rules_path=ROOT / "config/security/assessment-rules.json",
        )
