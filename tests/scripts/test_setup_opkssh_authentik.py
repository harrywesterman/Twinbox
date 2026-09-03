import subprocess
import unittest
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]


class TestSetupOpksshAuthentik(unittest.TestCase):
    def test_script_syntax(self):
        script = WORKSPACE_ROOT / "scripts" / "manager" / "setup-opkssh-authentik.sh"
        result = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)

    def test_install_browser_ssh_run_syntax(self):
        run_script = (
            WORKSPACE_ROOT
            / "categories"
            / "talos-cluster"
            / "steps"
            / "install-browser-ssh"
            / "run.sh"
        )
        result = subprocess.run(
            ["bash", "-n", str(run_script)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)

    def test_opkssh_issuer_is_stored_as_authentik_canonical_issuer(self):
        script = WORKSPACE_ROOT / "scripts" / "manager" / "setup-opkssh-authentik.sh"
        text = script.read_text(encoding="utf-8")

        self.assertIn(
            'opkssh_issuer_url="https://authentik.${public_zone_name}/application/o/opkssh/"',
            text,
        )
        self.assertNotIn(
            'opkssh_issuer_url="https://authentik.${public_zone_name}/application/o/opkssh"\n',
            text,
        )

    def test_opkssh_allows_coder_workspace_login_callback(self):
        script = WORKSPACE_ROOT / "scripts" / "manager" / "setup-opkssh-authentik.sh"
        text = script.read_text(encoding="utf-8")

        self.assertIn("public_zone_regex=", text)
        self.assertIn("sed 's/[.]/[.]/g'", text)
        self.assertIn(
            'opkssh_coder_redirect_uri_regex="^https://coder[.]${public_zone_regex}/.*callback.*$"',
            text,
        )
        self.assertIn('matching_mode: "regex"', text)
        self.assertIn("coder_redirect_uri_regex", text)


if __name__ == "__main__":
    unittest.main()
