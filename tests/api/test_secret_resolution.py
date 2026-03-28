import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import request


REPO_ROOT = Path(__file__).resolve().parents[2]


def _find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _wait_for_health(base_url, timeout=10):
    start = time.time()
    while time.time() - start < timeout:
      try:
        with request.urlopen(f"{base_url}/api/health", timeout=1) as resp:
            if resp.status == 200:
                return
      except Exception:
        time.sleep(0.2)
    raise RuntimeError("manager-api did not become healthy in time")


def test_secret_endpoint_resolves_wiredoor_items_by_name():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        bin_dir = root / "bin"
        runtime_dir = root / "bw-runtime"
        log_file = root / "bw.log"
        state_file = root / "state.json"
        ready_file = root / "vaultwarden-ready"
        client_id_file = root / "client-id"
        client_secret_file = root / "client-secret"
        password_file = root / "password"
        bw_script = bin_dir / "bw"

        bin_dir.mkdir(parents=True, exist_ok=True)
        runtime_dir.mkdir(parents=True, exist_ok=True)
        ready_file.write_text("", encoding="utf-8")
        client_id_file.write_text("user.example", encoding="utf-8")
        client_secret_file.write_text("secret-value", encoding="utf-8")
        password_file.write_text("master-password", encoding="utf-8")
        state_file.write_text(
            json.dumps({
                "status": "locked",
                "serverUrl": "http://vaultwarden:80",
                "userEmail": "twinbox@local",
            }),
            encoding="utf-8",
        )
        bw_script.write_text(
            "#!/usr/bin/env python3\n"
            "import json\n"
            "import os\n"
            "import sys\n"
            "from pathlib import Path\n"
            "\n"
            "state_file = Path(os.environ['BW_STATE_FILE'])\n"
            "log_file = Path(os.environ['BW_LOG_FILE'])\n"
            "args = sys.argv[1:]\n"
            "log_file.write_text(log_file.read_text(encoding='utf-8') + ' '.join(args) + '\\n', encoding='utf-8') if log_file.exists() else log_file.write_text(' '.join(args) + '\\n', encoding='utf-8')\n"
            "state = json.loads(state_file.read_text(encoding='utf-8')) if state_file.exists() else {'status': 'unauthenticated', 'serverUrl': '', 'userEmail': ''}\n"
            "if args[:2] == ['config', 'server']:\n"
            "    state['serverUrl'] = args[2]\n"
            "    state_file.write_text(json.dumps(state), encoding='utf-8')\n"
            "    sys.exit(0)\n"
            "if args == ['status']:\n"
            "    print(json.dumps(state))\n"
            "    sys.exit(0)\n"
            "if args == ['unlock', '--passwordfile', os.environ['BW_PASSWORD_FILE'], '--raw']:\n"
            "    print('session-token')\n"
            "    sys.exit(0)\n"
            "if args == ['sync', '--session', 'session-token']:\n"
            "    sys.exit(0)\n"
            "if args[:3] == ['list', 'items', '--search'] and args[-2:] == ['--session', 'session-token']:\n"
            "    if args[3] != 'twinbox/global/wiredoor-gateway':\n"
            "        raise SystemExit(f'unexpected search: {args[3]}')\n"
            "    print(json.dumps([{\n"
            "        'id': 'item-123',\n"
            "        'name': 'twinbox/global/wiredoor-gateway',\n"
            "        'login': {'username': 'https://wiredoor.bierineenweek.nl', 'password': 'wiredoor-token-abc'},\n"
            "        'fields': [\n"
            "            {'name': 'url', 'value': 'https://wiredoor.bierineenweek.nl', 'type': 0},\n"
            "            {'name': 'token', 'value': 'wiredoor-token-abc', 'type': 0},\n"
            "        ],\n"
            "    }]))\n"
            "    sys.exit(0)\n"
            "raise SystemExit(f'unexpected args: {args}')\n",
            encoding="utf-8",
        )
        bw_script.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["BW_STATE_FILE"] = str(state_file)
        env["BW_LOG_FILE"] = str(log_file)
        env["BW_PASSWORD_FILE"] = str(password_file)
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["WORKSPACE_ROOT"] = str(REPO_ROOT)
        env["BITWARDENCLI_APPDATA_DIR"] = str(runtime_dir)
        env["TWINBOX_SECRET_BACKEND"] = "vaultwarden"
        env["VAULTWARDEN_READY_FILE"] = str(ready_file)
        env["VAULTWARDEN_PASSWORD_FILE"] = str(password_file)
        env["VAULTWARDEN_CLIENTID_FILE"] = str(client_id_file)
        env["VAULTWARDEN_CLIENTSECRET_FILE"] = str(client_secret_file)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            with request.urlopen(
                f"{base}/api/secrets/twinbox/global/wiredoor-gateway",
                timeout=3,
            ) as resp:
                body = json.loads(resp.read().decode("utf-8"))

            assert resp.status == 200
            assert body["data"]["login"]["username"] == "https://wiredoor.bierineenweek.nl"
            assert body["data"]["login"]["password"] == "wiredoor-token-abc"

            with request.urlopen(
                f"{base}/api/secret-values/twinbox/global/wiredoor-gateway?source=login&property=password",
                timeout=3,
            ) as resp:
                value_body = json.loads(resp.read().decode("utf-8"))

            assert resp.status == 200
            assert value_body["value"] == "wiredoor-token-abc"

            log_lines = log_file.read_text(encoding="utf-8").splitlines()
            assert any("list items --search twinbox/global/wiredoor-gateway" in line for line in log_lines)
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_secret_value_endpoint_returns_404_for_empty_wiredoor_token():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        bin_dir = root / "bin"
        runtime_dir = root / "bw-runtime"
        log_file = root / "bw.log"
        state_file = root / "state.json"
        ready_file = root / "vaultwarden-ready"
        client_id_file = root / "client-id"
        client_secret_file = root / "client-secret"
        password_file = root / "password"
        bw_script = bin_dir / "bw"

        bin_dir.mkdir(parents=True, exist_ok=True)
        runtime_dir.mkdir(parents=True, exist_ok=True)
        ready_file.write_text("", encoding="utf-8")
        client_id_file.write_text("user.example", encoding="utf-8")
        client_secret_file.write_text("secret-value", encoding="utf-8")
        password_file.write_text("master-password", encoding="utf-8")
        state_file.write_text(
            json.dumps({
                "status": "locked",
                "serverUrl": "http://vaultwarden:80",
                "userEmail": "twinbox@local",
            }),
            encoding="utf-8",
        )
        bw_script.write_text(
            "#!/usr/bin/env python3\n"
            "import json\n"
            "import os\n"
            "import sys\n"
            "from pathlib import Path\n"
            "\n"
            "state_file = Path(os.environ['BW_STATE_FILE'])\n"
            "args = sys.argv[1:]\n"
            "state = json.loads(state_file.read_text(encoding='utf-8')) if state_file.exists() else {'status': 'unauthenticated', 'serverUrl': '', 'userEmail': ''}\n"
            "if args[:2] == ['config', 'server']:\n"
            "    state['serverUrl'] = args[2]\n"
            "    state_file.write_text(json.dumps(state), encoding='utf-8')\n"
            "    sys.exit(0)\n"
            "if args == ['status']:\n"
            "    print(json.dumps(state))\n"
            "    sys.exit(0)\n"
            "if args == ['unlock', '--passwordfile', os.environ['BW_PASSWORD_FILE'], '--raw']:\n"
            "    print('session-token')\n"
            "    sys.exit(0)\n"
            "if args == ['sync', '--session', 'session-token']:\n"
            "    sys.exit(0)\n"
            "if args[:3] == ['list', 'items', '--search'] and args[-2:] == ['--session', 'session-token']:\n"
            "    print(json.dumps([{\n"
            "        'id': 'item-123',\n"
            "        'name': 'twinbox/global/wiredoor-gateway',\n"
            "        'login': {'username': 'https://wiredoor.bierineenweek.nl', 'password': ''},\n"
            "        'fields': [\n"
            "            {'name': 'url', 'value': 'https://wiredoor.bierineenweek.nl', 'type': 0},\n"
            "            {'name': 'token', 'value': '', 'type': 0},\n"
            "        ],\n"
            "    }]))\n"
            "    sys.exit(0)\n"
            "raise SystemExit(f'unexpected args: {args}')\n",
            encoding="utf-8",
        )
        bw_script.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["BW_STATE_FILE"] = str(state_file)
        env["BW_LOG_FILE"] = str(log_file)
        env["BW_PASSWORD_FILE"] = str(password_file)
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["WORKSPACE_ROOT"] = str(REPO_ROOT)
        env["BITWARDENCLI_APPDATA_DIR"] = str(runtime_dir)
        env["TWINBOX_SECRET_BACKEND"] = "vaultwarden"
        env["VAULTWARDEN_READY_FILE"] = str(ready_file)
        env["VAULTWARDEN_PASSWORD_FILE"] = str(password_file)
        env["VAULTWARDEN_CLIENTID_FILE"] = str(client_id_file)
        env["VAULTWARDEN_CLIENTSECRET_FILE"] = str(client_secret_file)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            try:
                request.urlopen(
                    f"{base}/api/secret-values/twinbox/global/wiredoor-gateway?source=login&property=password",
                    timeout=3,
                )
            except request.HTTPError as error:
                assert error.code == 404
                body = json.loads(error.read().decode("utf-8"))
                assert body["error"] == "secret login property password is not available"
            else:
                raise AssertionError("expected 404 for empty wiredoor token")
        finally:
            proc.terminate()
            proc.wait(timeout=5)
