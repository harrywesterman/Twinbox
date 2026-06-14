import subprocess
import unittest
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]


class TestInstallOpksshStep(unittest.TestCase):
    def test_run_script_syntax(self):
        script = (
            WORKSPACE_ROOT
            / "categories"
            / "talos-cluster"
            / "steps"
            / "install-opkssh"
            / "run.sh"
        )
        result = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)

    def test_install_opkssh_on_host_syntax(self):
        script = WORKSPACE_ROOT / "scripts" / "manager" / "install-opkssh-on-host.sh"
        result = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)


if __name__ == "__main__":
    unittest.main()
