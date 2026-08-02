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
