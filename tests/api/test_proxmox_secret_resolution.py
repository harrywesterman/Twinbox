import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import request


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


def test_ip_suggestions_can_use_secret_broker_for_proxmox_api_fallback():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        data_dir = root / "data"
        bootstrap_root = root / "bootstrap"
        secret_dir = bootstrap_root / "secrets" / "global"
        bin_dir = root / "bin"
        curl_log = root / "curl.log"
        ping_mock = bin_dir / "ping"
        ip_mock = bin_dir / "ip"
        curl_mock = bin_dir / "curl"
        resolv_conf = root / "resolv.conf"

        bin_dir.mkdir(parents=True, exist_ok=True)
        secret_dir.mkdir(parents=True, exist_ok=True)
        (secret_dir / "proxmox.json").write_text(
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
        ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        ip_mock.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "-o" ]; then echo \'2: eth0    inet 192.168.2.20/24 brd 192.168.2.255 scope global eth0\'; exit 0; fi\n'
            'if [ "$1" = "route" ]; then echo \'default via 192.168.2.1 dev eth0\'; exit 0; fi\n'
            "exit 1\n",
            encoding="utf-8",
        )
        ip_mock.chmod(0o755)
        curl_mock.write_text(
            "#!/bin/sh\n"
            f'printf \'%s\\n\' "$*" >> "{curl_log}"\n'
            'case "$*" in\n'
            "  *'/access/ticket'*)\n"
            '    echo \'{"data":{"ticket":"ticket-123"}}\'\n'
            "    ;;\n"
            "  *'/cluster/resources?type=vm'*)\n"
            '    echo \'{"data":[{"vmid":100},{"vmid":101}]}\'\n'
            "    ;;\n"
            "  *)\n"
            "    echo '{\"data\":[]}'\n"
            "    ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        curl_mock.chmod(0o755)
        resolv_conf.write_text("nameserver 1.1.1.1\n", encoding="utf-8")

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["TWINBOX_SECRET_BACKEND"] = "filesystem"
        env["TWINBOX_BOOTSTRAP_DIR"] = str(bootstrap_root)
        env["TWINBOX_SECRET_ITEM_PREFIX"] = "twinbox"
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_IP_BIN"] = str(ip_mock)
        env["MANAGER_API_RESOLV_CONF"] = str(resolv_conf)
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            _wait_for_health(f"http://127.0.0.1:{port}")
            with request.urlopen(
                f"http://127.0.0.1:{port}/api/ip-suggestions?management_ip=192.168.2.20&node_count=2",
                timeout=3,
            ) as resp:
                body = json.loads(resp.read().decode("utf-8"))

            assert resp.status == 200
            assert body["start_vmid"] == 102
            assert body["vmid_block"] == [102, 103]

            curl_text = curl_log.read_text(encoding="utf-8")
            assert "/access/ticket" in curl_text
            assert "/cluster/resources?type=vm" in curl_text
            assert "username=root%40pam" in curl_text
            assert "password=super-secret" in curl_text
        finally:
            proc.terminate()
            proc.wait(timeout=5)
