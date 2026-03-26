import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_ensure_bitwarden_login_reuses_locked_state_without_relogin():
    with tempfile.TemporaryDirectory() as td:
      root = Path(td)
      bin_dir = root / "bin"
      runtime_dir = root / "bw-runtime"
      log_file = root / "bw.log"
      state_file = root / "state.json"
      client_id_file = root / "client-id"
      client_secret_file = root / "client-secret"
      bw_script = bin_dir / "bw"

      bin_dir.mkdir(parents=True, exist_ok=True)
      client_id_file.write_text("user.example", encoding="utf-8")
      client_secret_file.write_text("secret-value", encoding="utf-8")
      state_file.write_text(
          json.dumps({
              "status": "locked",
              "serverUrl": "http://127.0.0.1:8222",
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
          "if args == ['logout']:\n"
          "    state = {'status': 'unauthenticated', 'serverUrl': state.get('serverUrl', ''), 'userEmail': ''}\n"
          "    state_file.write_text(json.dumps(state), encoding='utf-8')\n"
          "    sys.exit(0)\n"
          "if args == ['login', '--apikey']:\n"
          "    assert os.environ.get('BW_CLIENTID') == 'user.example'\n"
          "    assert os.environ.get('BW_CLIENTSECRET') == 'secret-value'\n"
          "    state = {'status': 'locked', 'serverUrl': state.get('serverUrl', ''), 'userEmail': 'twinbox@local'}\n"
          "    state_file.write_text(json.dumps(state), encoding='utf-8')\n"
          "    sys.exit(0)\n"
          "raise SystemExit(f'unexpected args: {args}')\n",
          encoding="utf-8",
      )
      bw_script.chmod(0o755)

      env = os.environ.copy()
      env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
      env["BW_STATE_FILE"] = str(state_file)
      env["BW_LOG_FILE"] = str(log_file)

      result = subprocess.run(
          [
              "node",
              "--input-type=module",
              "-e",
              (
                  "import { ensureBitwardenLogin } from './lib/secrets/bitwarden-cli.mjs';"
                  "ensureBitwardenLogin({"
                  f"BITWARDENCLI_APPDATA_DIR: {json.dumps(str(runtime_dir))},"
                  f"VAULTWARDEN_CLIENTID_FILE: {json.dumps(str(client_id_file))},"
                  f"VAULTWARDEN_CLIENTSECRET_FILE: {json.dumps(str(client_secret_file))}"
                  "}, 'http://vaultwarden:80');"
              ),
          ],
          cwd=REPO_ROOT,
          env=env,
          capture_output=True,
          text=True,
          check=False,
      )

      assert result.returncode == 0, result.stderr or result.stdout
      log_lines = log_file.read_text(encoding="utf-8").splitlines()
      assert log_lines[:2] == ["config server http://vaultwarden:80", "status"]
      assert "logout" not in log_lines
      assert "login --apikey" not in log_lines


def test_ensure_bitwarden_login_reuses_locked_session_on_same_server():
    with tempfile.TemporaryDirectory() as td:
      root = Path(td)
      bin_dir = root / "bin"
      runtime_dir = root / "bw-runtime"
      log_file = root / "bw.log"
      state_file = root / "state.json"
      client_id_file = root / "client-id"
      client_secret_file = root / "client-secret"
      bw_script = bin_dir / "bw"

      bin_dir.mkdir(parents=True, exist_ok=True)
      client_id_file.write_text("user.example", encoding="utf-8")
      client_secret_file.write_text("secret-value", encoding="utf-8")
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
          "if args == ['logout']:\n"
          "    raise SystemExit('logout should not be called for locked same-server session')\n"
          "if args == ['login', '--apikey']:\n"
          "    raise SystemExit('login should not be called for locked same-server session')\n"
          "raise SystemExit(f'unexpected args: {args}')\n",
          encoding="utf-8",
      )
      bw_script.chmod(0o755)

      env = os.environ.copy()
      env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
      env["BW_STATE_FILE"] = str(state_file)
      env["BW_LOG_FILE"] = str(log_file)

      result = subprocess.run(
          [
              "node",
              "--input-type=module",
              "-e",
              (
                  "import { ensureBitwardenLogin } from './lib/secrets/bitwarden-cli.mjs';"
                  "ensureBitwardenLogin({"
                  f"BITWARDENCLI_APPDATA_DIR: {json.dumps(str(runtime_dir))},"
                  f"VAULTWARDEN_CLIENTID_FILE: {json.dumps(str(client_id_file))},"
                  f"VAULTWARDEN_CLIENTSECRET_FILE: {json.dumps(str(client_secret_file))}"
                  "}, 'http://vaultwarden:80');"
              ),
          ],
          cwd=REPO_ROOT,
          env=env,
          capture_output=True,
          text=True,
          check=False,
      )

      assert result.returncode == 0, result.stderr or result.stdout
      log_lines = log_file.read_text(encoding="utf-8").splitlines()
      assert log_lines == ["config server http://vaultwarden:80", "status"]


def test_secret_broker_ensure_session_continues_when_sync_fails():
    with tempfile.TemporaryDirectory() as td:
      root = Path(td)
      bin_dir = root / "bin"
      runtime_dir = root / "bw-runtime"
      log_file = root / "bw.log"
      client_id_file = root / "client-id"
      client_secret_file = root / "client-secret"
      password_file = root / "password"
      ready_file = root / "vaultwarden-ready"
      bw_script = bin_dir / "bw"

      bin_dir.mkdir(parents=True, exist_ok=True)
      runtime_dir.mkdir(parents=True, exist_ok=True)
      ready_file.write_text("", encoding="utf-8")
      client_id_file.write_text("user.example", encoding="utf-8")
      client_secret_file.write_text("secret-value", encoding="utf-8")
      password_file.write_text("master-password", encoding="utf-8")
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
          "if args == ['logout']:\n"
          "    state = {'status': 'unauthenticated', 'serverUrl': state.get('serverUrl', ''), 'userEmail': ''}\n"
          "    state_file.write_text(json.dumps(state), encoding='utf-8')\n"
          "    sys.exit(0)\n"
          "if args == ['login', '--apikey']:\n"
          "    assert os.environ.get('BW_CLIENTID') == 'user.example'\n"
          "    assert os.environ.get('BW_CLIENTSECRET') == 'secret-value'\n"
          "    state = {'status': 'locked', 'serverUrl': state.get('serverUrl', ''), 'userEmail': 'twinbox@local'}\n"
          "    state_file.write_text(json.dumps(state), encoding='utf-8')\n"
          "    sys.exit(0)\n"
          "if args[:1] == ['unlock']:\n"
          "    print('session-123')\n"
          "    sys.exit(0)\n"
          "if args[:1] == ['sync']:\n"
          "    print('Syncing failed: TypeError: Cannot read properties of null (reading \"toString\")', file=sys.stderr)\n"
          "    sys.exit(1)\n"
          "raise SystemExit(f'unexpected args: {args}')\n",
          encoding="utf-8",
      )
      bw_script.chmod(0o755)

      env = os.environ.copy()
      env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
      env["BW_STATE_FILE"] = str(root / "state.json")
      env["BW_LOG_FILE"] = str(log_file)

      result = subprocess.run(
          [
              "node",
              "--input-type=module",
              "-e",
              (
                  "import { createSecretBroker } from './lib/secrets/broker.mjs';"
                  "const broker = createSecretBroker({"
                  f"BITWARDENCLI_APPDATA_DIR: {json.dumps(str(runtime_dir))},"
                  f"VAULTWARDEN_CLIENTID_FILE: {json.dumps(str(client_id_file))},"
                  f"VAULTWARDEN_CLIENTSECRET_FILE: {json.dumps(str(client_secret_file))},"
                  f"VAULTWARDEN_PASSWORD_FILE: {json.dumps(str(password_file))},"
                  f"VAULTWARDEN_READY_FILE: {json.dumps(str(ready_file))},"
                  "VAULTWARDEN_SERVER_URL: 'http://vaultwarden:80'"
                  "});"
                  "broker.ensureSession();"
              ),
          ],
          cwd=REPO_ROOT,
          env=env,
          capture_output=True,
          text=True,
          check=False,
      )

      assert result.returncode == 0, result.stderr or result.stdout
      log_lines = log_file.read_text(encoding="utf-8").splitlines()
      assert log_lines.index("config server http://vaultwarden:80") < log_lines.index("login --apikey")
      assert "login --apikey" in log_lines
      unlock_line = next(line for line in log_lines if line.startswith("unlock --passwordfile "))
      assert log_lines.index("login --apikey") < log_lines.index(unlock_line)
      assert "sync --session session-123" in " ".join(log_lines)
