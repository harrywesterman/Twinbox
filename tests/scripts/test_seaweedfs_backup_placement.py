import json
import os
import subprocess
from pathlib import Path

import pytest


@pytest.mark.parametrize(
    "scenario", ["selected-host", "occupied-later", "existing-host", "retry-occupied"]
)
def test_seaweedfs_runner_placement_and_ip_race(tmp_path, scenario):
    repo = Path(__file__).resolve().parents[2]
    bins = tmp_path / "bin"
    bins.mkdir()
    bootstrap = tmp_path / "bootstrap"
    profile_dir = bootstrap / "secrets/cluster/test/backup-storage"
    profile_dir.mkdir(parents=True)
    for name in ["ca.key", "ca.crt", "server.key", "server.crt", "vm-ssh-key", "vm-ssh-key.pub"]:
        (profile_dir / name).write_text("test")
    profile = profile_dir / "metadata.json"
    if scenario in {"existing-host", "retry-occupied"}:
        profile.write_text(
            json.dumps(
                {
                    "vm": {
                        "vm_id": 123,
                        "node": "original" if scenario == "existing-host" else "chosen",
                        "datastore": "disk",
                        "data_disk_gb": 500,
                        "ip_address": "192.0.2.5",
                    }
                }
            )
        )
    mocks = {
        "xorriso": '#!/bin/sh\nfor arg do case "$arg" in */network-config) cp "$arg" "$TEST_NETWORK";; esac; done\ntouch "$4"\n',
        "openssl": "#!/bin/sh\necho fingerprint-test\n",
        "tofu": '#!/bin/sh\ncase "$*" in *apply*) echo "$TF_VAR_node_name $TF_VAR_file_datastore_id" > "$TEST_APPLY"; exit 44;; esac\n',
        "ping": '#!/bin/sh\nif [ -f "$TEST_PROBED" ] && [ "$TEST_SCENARIO" = occupied-later ]; then exit 0; fi\ntouch "$TEST_PROBED"\nexit 1\n',
        "ip": "#!/bin/sh\nexit 1\n",
        "curl": """#!/bin/sh
case "$*" in
  *access/ticket*) echo '{"data":{"ticket":"test","CSRFPreventionToken":"test"}}';;
  *'resources?type=node'*) echo '{"data":[{"node":"chosen","status":"online","maxmem":17179869184,"mem":0}]}';;
  *'resources?type=vm'*) echo '{"data":[]}';;
  */storage*) echo '{"data":[{"storage":"disk","content":"images","active":1,"avail":1073741824000},{"storage":"files","content":"iso,snippets","active":1,"avail":10737418240}]}';;
  */network*) echo '{"data":[{"iface":"vmbr-test","active":1}]}';;
  */nextid*) echo '{"data":123}';;
  *) [ "$TEST_SCENARIO" = retry-occupied ] && exit 0; exit 1;;
esac
""",
    }
    for name, source in mocks.items():
        file = bins / name
        file.write_text(source)
        file.chmod(0o755)
    marker = tmp_path / "apply"
    env = {
        **os.environ,
        "PATH": f"{bins}:{os.environ['PATH']}",
        "WORKSPACE_ROOT": str(repo),
        "TWINBOX_BOOTSTRAP_DIR": str(bootstrap),
        "TWINBOX_CLUSTER_ID": "test",
        "MANAGER_DATA_DIR": str(tmp_path / "data"),
        "MANAGEMENT_VM_IP": "192.0.2.4",
        "PROXMOX_HOST": "proxmox.test",
        "PROXMOX_USER": "test",
        "PROXMOX_PASSWORD": "test",
        "TEST_APPLY": str(marker),
        "TEST_NETWORK": str(tmp_path / "network.json"),
        "TEST_PROBED": str(tmp_path / "probed"),
        "TEST_SCENARIO": scenario,
        "STEP_CONTEXT_JSON": json.dumps(
            {
                "cluster": {
                    "id": "test",
                    "bridge": "vmbr-test",
                    "gateway_ip": "192.0.2.1",
                    "node_prefix_length": 29,
                    "dns_servers": ["192.0.2.1"],
                }
            }
        ),
        "STEP_INPUTS_JSON": json.dumps(
            {
                "seaweedfs_node": "chosen",
                "seaweedfs_datastore": "disk",
                "seaweedfs_data_disk_gb": 500,
                "seaweedfs_ip": "192.0.2.5",
            }
        ),
    }
    result = subprocess.run(
        ["bash", "scripts/manager/provision-seaweedfs-backup-vm.sh"],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if scenario == "selected-host":
        assert result.returncode == 44, result.stdout + result.stderr
        assert marker.read_text().strip() == "chosen files"
        network = json.loads((tmp_path / "network.json").read_text())["ethernets"]["primary"]
        assert network["addresses"] == ["192.0.2.5/29"]
        assert network["routes"] == [{"to": "default", "via": "192.0.2.1"}]
        assert network["nameservers"]["addresses"] == ["192.0.2.1"]
    else:
        assert result.returncode != 0
        assert not marker.exists()
        if scenario in {"occupied-later", "retry-occupied"}:
            assert "became occupied" in result.stderr
            assert profile.exists() == (scenario == "retry-occupied")
        else:
            assert "Refusing to move" in result.stderr
            assert json.loads(profile.read_text())["vm"]["node"] == "original"
