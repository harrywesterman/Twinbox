"""Contract checks for Velero UI Helm values and secret wiring."""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_velero_ui_uses_the_external_jwt_signing_secret():
    values = yaml.safe_load((REPO_ROOT / "gitops/values/velero-ui.yaml").read_text())
    external_secret = yaml.safe_load(
        (REPO_ROOT / "gitops/platform-apps/velero-ui/externalsecret.yaml").read_text()
    )

    secret_config = values["configuration"]["general"]["secretPassPhrase"]
    assert secret_config["useSecret"] is True
    assert secret_config["existingSecret"] == external_secret["spec"]["target"]["name"]
    secret_key = secret_config["key"]
    secret_entry = next(
        entry for entry in external_secret["spec"]["data"] if entry["secretKey"] == secret_key
    )
    assert secret_entry["remoteRef"]["property"] == secret_key
