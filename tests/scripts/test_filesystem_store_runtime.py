import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_filesystem_store_lists_global_secret_items_without_external_cli():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bootstrap_root = root / "bootstrap"
        global_secret_dir = bootstrap_root / "secrets" / "global"
        global_secret_dir.mkdir(parents=True, exist_ok=True)
        (global_secret_dir / "proxmox.json").write_text(
            json.dumps(
                {
                    "username": "root@pam",
                    "password": "super-secret",
                    "host": "192.168.1.10",
                    "port": "8006",
                    "endpoint": "https://192.168.1.10:8006",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["TWINBOX_BOOTSTRAP_DIR"] = str(bootstrap_root)
        env["TWINBOX_SECRET_BACKEND"] = "filesystem"
        env["TWINBOX_SECRET_ITEM_PREFIX"] = "twinbox"

        result = subprocess.run(
            [
                "node",
                "--input-type=module",
                "-e",
                (
                    "import { ensureSecretSession, listSecretItems, readSecretSessionStatus } from './lib/secrets/filesystem-store.mjs';"
                    "const status = readSecretSessionStatus();"
                    "const session = ensureSecretSession();"
                    "const items = listSecretItems(process.env, 'twinbox/global/proxmox', session);"
                    "console.log(JSON.stringify({"
                    "status,"
                    "session,"
                    "itemName: items[0]?.name,"
                    "endpoint: items[0]?.fields?.find((field) => field.name === 'endpoint')?.value,"
                    "}));"
                ),
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["status"]["status"] == "filesystem"
        assert payload["session"]["status"] == "filesystem"
        assert payload["itemName"] == "twinbox/global/proxmox"
        assert payload["endpoint"] == "https://192.168.1.10:8006"
