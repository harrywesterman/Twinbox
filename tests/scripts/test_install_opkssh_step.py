import subprocess
import unittest
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
ANSIBLE_MAINTENANCE = WORKSPACE_ROOT / "ansible" / "management-vm-maintenance.yml"
NETBIRD_CLOUD_INIT = (
    WORKSPACE_ROOT / "infra" / "opentofu" / "netbird" / "cloud-init" / "netbird.yaml.tftpl"
)


class TestInstallOpksshStep(unittest.TestCase):
    def test_run_script_syntax(self):
        script = (
            WORKSPACE_ROOT / "categories" / "talos-cluster" / "steps" / "install-opkssh" / "run.sh"
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

    def test_install_opkssh_uses_valid_provider_policy(self):
        script = WORKSPACE_ROOT / "scripts" / "manager" / "install-opkssh-on-host.sh"
        text = script.read_text(encoding="utf-8")

        self.assertIn('expiration_policy="${OPKSSH_EXPIRATION_POLICY:-24h}"', text)
        self.assertIn("12h|24h|48h|1week|oidc|oidc-refreshed", text)
        self.assertIn('ISSUER_URL="${OPKSSH_ISSUER_URL}"', text)
        self.assertIn("\\${ISSUER_URL} \\${CLIENT_ID} \\${EXPIRATION_POLICY}", text)
        self.assertNotIn("\\${ISSUER_URL} \\${CLIENT_ID} 16h", text)
        self.assertIn("/var/log/opkssh.log", text)
        self.assertIn("opkssh audit failed; continuing", text)

    def test_other_opkssh_provisioning_paths_use_valid_provider_policy(self):
        ansible_text = ANSIBLE_MAINTENANCE.read_text(encoding="utf-8")
        cloud_init_text = NETBIRD_CLOUD_INIT.read_text(encoding="utf-8")

        self.assertIn("{{ opkssh_issuer_url }} {{ opkssh_client_id }} 24h", ansible_text)
        self.assertIn("${opkssh_issuer_url} ${opkssh_client_id} 24h", cloud_init_text)
        self.assertIn("failed_when: false", ansible_text)
        self.assertIn("/usr/local/bin/opkssh audit || true", cloud_init_text)
        self.assertIn("/var/log/opkssh.log", ansible_text)
        self.assertIn("/var/log/opkssh.log", cloud_init_text)
        self.assertNotIn("{{ opkssh_issuer_url }} {{ opkssh_client_id }} 16h", ansible_text)
        self.assertNotIn("${opkssh_issuer_url} ${opkssh_client_id} 16h", cloud_init_text)


if __name__ == "__main__":
    unittest.main()
