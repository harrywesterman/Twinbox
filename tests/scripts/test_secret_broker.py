import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def _write_fake_bw(bin_dir: Path, state_dir: Path):
    script = bin_dir / "bw"
    script.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        f"state_dir='{state_dir}'\n"
        "mkdir -p \"$state_dir\"\n"
        "cmd=\"${1:-}\"\n"
        "subcmd=\"${2:-}\"\n"
        "case \"$cmd $subcmd\" in\n"
        "  'config server')\n"
        "    exit 0\n"
        "    ;;\n"
        "  'status ') \n"
        "    printf '{\"status\":\"unauthenticated\"}'\n"
        "    exit 0\n"
        "    ;;\n"
        "  'login --apikey')\n"
        "    exit 0\n"
        "    ;;\n"
        "  'unlock --passwordfile')\n"
        "    printf 'session-123'\n"
        "    exit 0\n"
        "    ;;\n"
        "  'sync --session')\n"
        "    exit 0\n"
        "    ;;\n"
        "  'list items')\n"
        "    if [ -f \"$state_dir/item.json\" ]; then\n"
        "      printf '[%s]' \"$(cat \"$state_dir/item.json\")\"\n"
        "    else\n"
        "      printf '[]'\n"
        "    fi\n"
        "    exit 0\n"
        "    ;;\n"
        "  'get template')\n"
        "    printf '{\"login\":{\"uris\":[]},\"fields\":[]}'\n"
        "    exit 0\n"
        "    ;;\n"
        "  'encode ')\n"
        "    cat\n"
        "    exit 0\n"
        "    ;;\n"
        "  'create item')\n"
        "    cat > \"$state_dir/item.json\"\n"
        "    cat \"$state_dir/item.json\"\n"
        "    exit 0\n"
        "    ;;\n"
        "esac\n"
        "printf 'unexpected bw invocation: %s %s\\n' \"$cmd\" \"$subcmd\" >&2\n"
        "exit 1\n",
        encoding="utf-8",
    )
    script.chmod(0o755)


def test_secret_broker_auto_seeds_missing_proxmox_item():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bin_dir = root / "bin"
        state_dir = root / "state"
        appdata_dir = root / "appdata"
        bin_dir.mkdir(parents=True, exist_ok=True)
        state_dir.mkdir(parents=True, exist_ok=True)
        appdata_dir.mkdir(parents=True, exist_ok=True)

        _write_fake_bw(bin_dir, state_dir)

        for name, value in {
            "vaultwarden-client-id": "client-id",
            "vaultwarden-client-secret": "client-secret",
            "vaultwarden-password": "vault-password",
        }.items():
            (root / name).write_text(value, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["BITWARDENCLI_APPDATA_DIR"] = str(appdata_dir)
        env["TWINBOX_SECRET_BACKEND"] = "vaultwarden"
        env["VAULTWARDEN_SERVER_URL"] = "http://vaultwarden:80"
        env["VAULTWARDEN_CLIENTID_FILE"] = str(root / "vaultwarden-client-id")
        env["VAULTWARDEN_CLIENTSECRET_FILE"] = str(root / "vaultwarden-client-secret")
        env["VAULTWARDEN_PASSWORD_FILE"] = str(root / "vaultwarden-password")
        env["PROXMOX_HOST"] = "192.168.1.10"
        env["PROXMOX_PORT"] = "8006"
        env["PROXMOX_USER"] = "root@pam"
        env["PROXMOX_PASSWORD"] = "super-secret"

        proc = subprocess.run(
            [
                "node",
                "--input-type=module",
                "-e",
                (
                    "import { createSecretBroker } from './lib/secrets/broker.mjs';\n"
                    "const broker = createSecretBroker(process.env);\n"
                    "const value = broker.resolveTextRef({ scope: 'global', item: 'proxmox', field: 'endpoint' });\n"
                    "console.log(value);\n"
                ),
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == "https://192.168.1.10:8006"

        item_json = (state_dir / "item.json").read_text(encoding="utf-8")
        assert '"name":"twinbox/global/proxmox"' in item_json
        assert '"username":"root@pam"' in item_json
        assert '"password":"super-secret"' in item_json
