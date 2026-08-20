import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TAG_RE = r"sha-[0-9a-f]{7}"

PIN_PATTERNS = {
    ".env.example": [rf"TWINBOX_IMAGE_TAG=({TAG_RE})"],
    "wizard/setup-wizard.sh": [rf'TWINBOX_IMAGE_TAG="({TAG_RE})"'],
    "scripts/manager/sync-manager-api-node-allowlist.sh": [rf"TWINBOX_IMAGE_TAG:-({TAG_RE})"],
    "scripts/manager-web-preview.sh": [rf"TWINBOX_VM_PREVIEW_IMAGE_TAG:-({TAG_RE})"],
    "docs/troubleshooting.md": [
        rf"twinbox-manager-api:({TAG_RE})",
        rf"twinbox-manager-worker:({TAG_RE})",
        rf"twinbox-manager-web:({TAG_RE})",
    ],
    "docs/env-reference.md": [rf"\| `TWINBOX_IMAGE_TAG` \| `({TAG_RE})` \|"],
    "docs/configuration.md": [rf"TWINBOX_IMAGE_TAG=({TAG_RE})"],
}


def _matches(path: str, pattern: str) -> list[str]:
    text = (REPO_ROOT / path).read_text(encoding="utf-8")
    return re.findall(pattern, text)


def test_manager_image_pins_are_consistent_sha_tags():
    tags_by_path = {}
    for path, patterns in PIN_PATTERNS.items():
        tags = []
        for pattern in patterns:
            tags.extend(_matches(path, pattern))
        assert tags, f"expected at least one manager image tag in {path}"
        tags_by_path[path] = tags

    all_tags = {tag for tags in tags_by_path.values() for tag in tags}
    assert len(all_tags) == 1, tags_by_path


def test_publish_workflow_replaces_existing_sha_pins():
    text = (REPO_ROOT / ".github/workflows/docker-publish.yml").read_text(encoding="utf-8")

    assert "(?:latest|sha-[0-9a-f]{7})" in text
    assert "Pinned image reference validation failed" in text
    assert 'TWINBOX_IMAGE_TAG="{sha}"' in text
    assert "TWINBOX_VM_PREVIEW_IMAGE_TAG:-{sha}" in text
