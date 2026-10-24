#!/usr/bin/env python3
"""Build a complete, digest-bound security report from Trivy image artifacts."""

import argparse
import hashlib
import json
import os
import re
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

from image_matrix import image_catalog

SEVERITIES = {"UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"}
RULES_PATH = Path("config/security/assessment-rules.json")


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_rules(path: Path = RULES_PATH) -> list[dict]:
    rules = json.loads(path.read_text(encoding="utf-8"))["rules"]
    for rule in rules:
        if rule.get("status") != "not_affected" or not rule.get("sourceSha256"):
            raise ValueError(f"Invalid assessment rule {rule.get('id')}")
    return rules


def verify_rule_sources(rules: list[dict]) -> None:
    """A changed/unavailable advisory revokes the automatic exception."""
    for rule in rules:
        rule["_sourceValid"] = False
        if not rule["sourceUrl"].startswith("https://security-tracker.debian.org/tracker/"):
            continue
        try:
            with urllib.request.urlopen(rule["sourceUrl"], timeout=10) as response:
                body = response.read(1024 * 1024 + 1)
            if len(body) <= 1024 * 1024:
                rule["_sourceValid"] = hashlib.sha256(body).hexdigest() == rule["sourceSha256"]
        except (OSError, ValueError):
            pass


def assess(finding: dict, image: dict, rules: list[dict], now: datetime | None = None) -> dict:
    now = now or datetime.now(UTC)
    matches = [
        rule
        for rule in rules
        if rule["vulnerabilityId"] == finding["vulnerabilityId"]
        and rule["packageName"] == finding["packageName"]
        and rule["installedVersion"] == finding["installedVersion"]
        and rule["distro"] == image["family"]
        and image["name"] is not None
        and image["name"].split(".", 1)[0] == rule["release"]
    ]
    if len(matches) != 1:
        return {
            "status": "needs_review",
            "reason": "No single exact assessment rule applies.",
            "ruleId": None,
        }
    rule = matches[0]
    if rule.get("_sourceValid") is False:
        return {
            "status": "needs_review",
            "reason": "Assessment source is unavailable or changed.",
            "ruleId": None,
        }
    expires = datetime.fromisoformat(rule["expiresAt"].replace("Z", "+00:00"))
    if expires <= now:
        return {
            "status": "needs_review",
            "reason": "Assessment evidence has expired.",
            "ruleId": None,
        }
    return {
        "status": rule["status"],
        "reason": rule["rationale"],
        "ruleId": rule["id"],
        "evidenceRefs": [
            {
                "url": rule["sourceUrl"],
                "sha256": rule["sourceSha256"],
                "reviewedAt": rule["reviewedAt"],
                "expiresAt": rule["expiresAt"],
            }
        ],
    }


def finding_id(
    image_key: str,
    digest: str,
    platform_name: str,
    target: str,
    package: str,
    package_identity: str,
    version: str,
    cve: str,
) -> str:
    fields = [image_key, digest, platform_name, target, package, package_identity, version, cve]
    return hashlib.sha256("\0".join(fields).encode()).hexdigest()


def load_report_item(root: Path, spec: dict, rules: list[dict]) -> dict:
    folder = root / spec["image_name"]
    raw = json.loads((folder / "report.json").read_text(encoding="utf-8"))
    digest = (folder / "digest.txt").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"ghcr\.io/[^@]+@sha256:[0-9a-f]{64}", digest):
        raise ValueError(f"Invalid immutable digest for {spec['image_name']}")
    metadata = raw.get("Metadata") or {}
    os_info = metadata.get("OS") or {}
    distro = {"family": os_info.get("Family"), "name": os_info.get("Name")}
    platform_name = (folder / "platform.txt").read_text(encoding="utf-8").strip()
    scanned_at = (folder / "scanned-at.txt").read_text(encoding="utf-8").strip()
    scanned_time = datetime.fromisoformat(scanned_at.replace("Z", "+00:00"))
    if scanned_time.tzinfo is None or scanned_time > datetime.now(UTC):
        raise ValueError(f"Invalid scan time for {spec['image_name']}")
    if not re.fullmatch(r"linux/(amd64|arm64|386|arm|s390x|ppc64le)(/[^\s]+)?", platform_name):
        raise ValueError(f"Invalid scan platform for {spec['image_name']}")
    results = raw.get("Results")
    if not isinstance(results, list) or raw.get("ArtifactName") != digest:
        raise ValueError(f"Trivy report lacks scan identity or Results for {spec['image_name']}")
    findings = []
    for result in results:
        target = result.get("Target") or "unknown"
        for vuln in result.get("Vulnerabilities") or []:
            severity = vuln.get("Severity")
            if severity not in SEVERITIES:
                raise ValueError(f"Invalid severity in {spec['image_name']}: {severity}")
            package = vuln.get("PkgName") or "unknown"
            version = vuln.get("InstalledVersion") or "unknown"
            cve = vuln.get("VulnerabilityID") or "unknown"
            assessment = assess(
                {"vulnerabilityId": cve, "packageName": package, "installedVersion": version},
                distro,
                rules,
            )
            findings.append(
                {
                    "id": finding_id(
                        spec["filter_key"],
                        digest,
                        platform_name,
                        target,
                        package,
                        vuln.get("PkgID") or "",
                        version,
                        cve,
                    ),
                    "vulnerabilityId": cve,
                    "packageName": package,
                    "packageIdentity": vuln.get("PkgID"),
                    "installedVersion": version,
                    "fixedVersions": vuln.get("FixedVersion", "").split(", ")
                    if vuln.get("FixedVersion")
                    else [],
                    "target": target,
                    "packageType": result.get("Type"),
                    "originalSeverity": severity,
                    "vendorStatus": vuln.get("Status"),
                    "advisoryUrls": vuln.get("PrimaryURL") and [vuln["PrimaryURL"]] or [],
                    **assessment,
                    "action": "no_action_required"
                    if assessment["status"] == "not_affected"
                    else ("update_available" if vuln.get("FixedVersion") else "investigate"),
                }
            )
    return {
        "key": spec["filter_key"],
        "logicalName": spec["image_name"],
        "publishedRef": spec["published_ref"],
        "digest": digest,
        "platform": platform_name,
        "distro": distro,
        "scanStatus": "complete",
        "scannedAt": scanned_at,
        "findings": findings,
    }


def build_report(
    root: Path,
    *,
    run_id: str,
    commit_sha: str,
    rules_path: Path = RULES_PATH,
    verify_sources: bool = False,
) -> dict:
    rules = read_rules(rules_path)
    if verify_sources:
        verify_rule_sources(rules)
    images = [load_report_item(root, spec, rules) for spec in image_catalog("")]
    return {
        "schemaVersion": 1,
        "repository": os.environ.get("GITHUB_REPOSITORY", "harrywesterman/Twinbox"),
        "workflowRunId": run_id,
        "commitSha": commit_sha,
        "generatedAt": utc_now(),
        "scannerVersion": None,
        "databaseUpdatedAt": None,
        "metadataNotes": [
            "Trivy scanner and vulnerability database versions are not present in the current scan artifacts."
        ],
        "coverage": {
            "expectedImages": len(image_catalog("")),
            "scannedImages": len(images),
            "platforms": sorted({i["platform"] for i in images}),
        },
        "images": images,
        "sourceErrors": [],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("scans", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = build_report(
        args.scans,
        run_id=os.environ.get("GITHUB_RUN_ID", "local"),
        commit_sha=os.environ.get("GITHUB_SHA", "unknown"),
        verify_sources=True,
    )
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
