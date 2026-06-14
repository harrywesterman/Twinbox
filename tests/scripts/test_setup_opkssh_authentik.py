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


if __name__ == "__main__":
    unittest.main()
