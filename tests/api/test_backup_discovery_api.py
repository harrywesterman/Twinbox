import json
import os
import subprocess
from pathlib import Path

from test_catalog_api import _find_free_port, _post_json, _wait_for_health


def test_backup_discovery_draft_saved_cluster_and_failure(tmp_path):
    repo = Path(__file__).resolve().parents[2]
    data = tmp_path / "data"
    bootstrap = tmp_path / "bootstrap"
    secrets = bootstrap / "secrets/global"
    secrets.mkdir(parents=True)
    (secrets / "proxmox.json").write_text(
        json.dumps({"host": "proxmox.test", "port": "8006", "username": "test", "password": "test"})
    )
    bins = tmp_path / "bin"
    bins.mkdir()
    curl = bins / "curl"
    curl.write_text(
        """#!/bin/sh
case "$*" in
  *access/ticket*) echo '{"data":{"ticket":"test"}}' ;;
  *'resources?type=node'*) echo '{"data":[{"node":"host-a","status":"online","maxmem":17179869184,"mem":0}]}' ;;
  *'resources?type=storage'*) echo '{"data":[{"node":"host-a","storage":"disk","content":"images","active":1,"avail":1073741824000},{"node":"host-a","storage":"files","content":"iso,import,snippets","active":1,"avail":10737418240}]}' ;;
  */storage*) echo '{"data":[{"storage":"disk","content":"images","active":1,"avail":1073741824000},{"storage":"files","content":"iso,import,snippets","active":1,"avail":10737418240}]}' ;;
  */network*) echo '{"data":[{"iface":"vmbr-test","active":1}]}' ;;
  *) exit 1 ;;
esac
"""
    )
    curl.chmod(0o755)
    port = _find_free_port()
    env = {
        **os.environ,
        "MANAGER_DATA_DIR": str(data),
        "MANAGER_API_PORT": str(port),
        "TWINBOX_BOOTSTRAP_DIR": str(bootstrap),
        "TWINBOX_SECRET_BACKEND": "filesystem",
        "MANAGEMENT_VM_IP": "192.0.2.4",
        "MANAGER_API_PING_BIN": "/usr/bin/false",
        "PATH": f"{bins}:{os.environ['PATH']}",
    }
    proc = subprocess.Popen(
        ["node", "manager-api/src/server.js"],
        cwd=repo,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        base = f"http://127.0.0.1:{port}"
        _wait_for_health(base)
        route = f"{base}/api/backup-storage/discovery"
        cluster = {
            "id": "test",
            "bridge": "vmbr-test",
            "gateway_ip": "192.0.2.1",
            "node_prefix_length": 29,
            "vip_ip": "192.0.2.2",
            "vm_ip_map": {"worker": "192.0.2.3"},
        }
        status, body = _post_json(route, {"cluster": cluster})
        assert status == 200, body
        assert body["ip"] == "192.0.2.5"
        assert body["hosts"][0]["node"] == "host-a"
        assert body["hosts"][0]["file_datastore"] == "files"
        assert body["existing"] is None
        status, body = _post_json(route, {"cluster": cluster, "exclude_ips": ["192.0.2.5"]})
        assert body["ip"] == "192.0.2.6"
        status, body = _post_json(route, {"cluster": cluster, "suggest_ip": False})
        assert body["ip"] == ""
        status, body = _post_json(route, {"cluster_id": "prd", "cluster": cluster})
        assert status == 200, body
        assert body["hosts"][0]["node"] == "host-a"
        status, body = _post_json(route, {"cluster": {}})
        assert status == 200, body
        assert body["ip"] == "192.0.2.2"
        assert _post_json(route, {"cluster_id": "../bad"})[0] == 400

        (data / "clusters/test.json").write_text(json.dumps(cluster))
        profile = bootstrap / "secrets/cluster/test/backup-storage"
        profile.mkdir(parents=True)
        (profile / "metadata.json").write_text(
            json.dumps(
                {
                    "secret_access_key": "never-return-this",
                    "vm": {
                        "vm_id": 123,
                        "node": "host-a",
                        "datastore": "disk",
                        "data_disk_gb": 500,
                        "ip_address": "192.0.2.6",
                        "ssh_private_key": "never-return-path",
                    },
                }
            )
        )
        status, body = _post_json(route, {"cluster_id": "test", "cluster": {}})
        assert status == 200, body
        assert body["ip"] == "192.0.2.6"
        assert body["existing"]["vm_id"] == 123
        assert "never-return" not in json.dumps(body)
        pbs_route = f"{base}/api/proxmox-backup/discovery"
        status, body = _post_json(pbs_route, {"cluster_id": "prd", "cluster": cluster})
        assert status == 200, body
        assert body["hosts"][0]["node"] == "host-a"
        curl.write_text("#!/bin/sh\nexit 1\n")
        assert _post_json(route, {"cluster_id": "test"})[0] == 400
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def test_web_image_includes_shared_backup_validation():
    repo = Path(__file__).resolve().parents[2]
    dockerfile = (repo / "manager-web/Dockerfile").read_text()
    assert "COPY lib/ /app/lib/" in dockerfile
    workflow = (repo / ".github/workflows/docker-publish.yml").read_text()
    web_matrix = workflow.split('"image_name": "twinbox-manager-web"', 1)[1].split("},", 1)[0]
    assert '"context": "."' in web_matrix
