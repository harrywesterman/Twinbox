import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_ensure_bitwarden_login_reauthenticates_locked_state_on_server_mismatch():
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
      assert "logout" in log_lines
      assert "login --apikey" in log_lines
