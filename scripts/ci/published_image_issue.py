#!/usr/bin/env python3
"""Keep one GitHub issue in sync with scheduled published-image scans."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from image_matrix import image_catalog

TITLE = "[Security] Published Twinbox image vulnerabilities"
MAX_FINDINGS_PER_IMAGE = 25


def load_findings(root: Path, image_names: list[str]) -> list[dict]:
    findings = []
    for name in image_names:
        report_path = root / name / "report.json"
        digest_path = root / name / "digest.txt"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        digest = digest_path.read_text(encoding="utf-8").strip()
        if not digest.startswith("ghcr.io/") or "@sha256:" not in digest:
            raise ValueError(f"Invalid image digest for {name}")
        vulnerabilities = []
        for result in report.get("Results", []):
            for vuln in result.get("Vulnerabilities") or []:
                if vuln.get("Severity") not in {"HIGH", "CRITICAL"}:
                    continue
                vulnerabilities.append(
                    {
                        "id": vuln["VulnerabilityID"],
                        "package": vuln["PkgName"],
                        "installed": vuln.get("InstalledVersion", "?"),
                        "fixed": vuln.get("FixedVersion") or "none published",
                        "severity": vuln["Severity"],
                    }
                )
        findings.append(
            {
                "name": name,
                "digest": digest,
                "vulnerabilities": sorted(
                    vulnerabilities,
                    key=lambda v: (v["severity"] != "CRITICAL", v["id"], v["package"]),
                ),
            }
        )
    return findings


def load_assessed_findings(report_path: Path) -> list[dict]:
    """Render the issue from the same full report consumed by the dashboard."""
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("schemaVersion") != 1 or len(report.get("images", [])) != 7:
        raise ValueError("Incomplete security report")
    return [
        {
            "name": image["logicalName"],
            "digest": image["digest"],
            "vulnerabilities": sorted(
                [
                    {
                        "id": finding["vulnerabilityId"],
                        "package": finding["packageName"],
                        "installed": finding["installedVersion"],
                        "fixed": ", ".join(finding["fixedVersions"]) or "none published",
                        "severity": finding["originalSeverity"],
                        "assessment": finding["status"],
                    }
                    for finding in image["findings"]
                    if finding["originalSeverity"] in {"HIGH", "CRITICAL"}
                    and finding["status"] != "not_affected"
                ],
                key=lambda finding: (
                    finding["severity"] != "CRITICAL",
                    finding["id"],
                    finding["package"],
                ),
            ),
        }
        for image in report["images"]
    ]


def render_body(findings: list[dict]) -> str:
    fingerprint = hashlib.sha256(json.dumps(findings, sort_keys=True).encode("utf-8")).hexdigest()
    lines = [
        "Daily Trivy scan of the seven published Twinbox images. Review the linked CVEs and update affected images or dependencies.",
        "",
        "The scan reports known package vulnerabilities; bundled runtime code may need a separate vendor advisory check.",
        "",
        "[Full scan reports](https://github.com/harrywesterman/Twinbox/actions/workflows/image-vulnerability-monitor.yml)",
        "",
        f"Findings fingerprint: `{fingerprint}`",
        "",
    ]
    lines.extend(
        [
            "Counts: "
            + ", ".join(
                f"{status}={sum(v.get('assessment') == status for item in findings for v in item['vulnerabilities'])}"
                for status in ("affected", "needs_review")
            ),
            "",
        ]
    )
    for item in findings:
        if not item["vulnerabilities"]:
            continue
        lines.extend([f"## `{item['name']}`", "", f"Image: `{item['digest']}`", ""])
        for vuln in item["vulnerabilities"][:MAX_FINDINGS_PER_IMAGE]:
            identifier = vuln["id"]
            link = (
                f"https://nvd.nist.gov/vuln/detail/{identifier}"
                if identifier.startswith("CVE-")
                else f"https://osv.dev/vulnerability/{identifier}"
            )
            lines.append(
                f"- **{vuln['severity']}** {vuln.get('assessment', 'unreviewed')} [{identifier}]({link}) · `{vuln['package']}` "
                f"`{vuln['installed']}` → `{vuln['fixed']}`"
            )
        remaining = len(item["vulnerabilities"]) - MAX_FINDINGS_PER_IMAGE
        if remaining > 0:
            lines.append(f"- {remaining} more findings in the latest scan artifact")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def decide_issue(existing: dict | None, findings: list[dict]) -> str:
    has_findings = any(item["vulnerabilities"] for item in findings)
    if not has_findings:
        return "close" if existing and existing["state"] == "OPEN" else "none"
    if existing is None:
        return "create"
    if existing["state"] == "CLOSED":
        return "reopen"
    return "update" if existing["body"] != render_body(findings) else "none"


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, text=True, capture_output=True).stdout


def main() -> None:
    root = Path(sys.argv[1])
    assessed = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    names = [image["image_name"] for image in image_catalog("")]
    findings = load_assessed_findings(assessed) if assessed else load_findings(root, names)
    repo = os.environ["GITHUB_REPOSITORY"]
    issues = json.loads(
        gh(
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "all",
            "--search",
            f'"{TITLE}" in:title',
            "--limit",
            "100",
            "--json",
            "number,title,state,body",
        )
    )
    matches = [issue for issue in issues if issue["title"] == TITLE]
    if len(matches) > 1:
        raise ValueError(f"More than one issue has title {TITLE}")
    existing = matches[0] if matches else None
    action = decide_issue(existing, findings)
    if action == "none":
        print("Published image issue is current")
        return
    if action == "close":
        gh("issue", "close", str(existing["number"]), "--repo", repo)
        return
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md") as body_file:
        body_file.write(render_body(findings))
        body_file.flush()
        if action == "create":
            gh(
                "issue",
                "create",
                "--repo",
                repo,
                "--title",
                TITLE,
                "--label",
                "security",
                "--body-file",
                body_file.name,
            )
        else:
            number = str(existing["number"])
            if action == "reopen":
                gh("issue", "reopen", number, "--repo", repo)
            gh("issue", "edit", number, "--repo", repo, "--body-file", body_file.name)


if __name__ == "__main__":
    main()
