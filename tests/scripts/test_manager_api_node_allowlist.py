import json
import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "manager" / "sync-manager-api-node-allowlist.sh"
BASE_CIDRS = "127.0.0.1/32,::1/128,172.16.0.0/12,10.0.0.0/8"


def _write_fake_kubectl(tmp_path: Path, node_ips: list[str], args_file: Path | None = None) -> Path:
    payload = {
        "items": [
            {
                "status": {
                    "addresses": [
                        {"type": "Hostname", "address": f"node-{index}"},
                        {"type": "InternalIP", "address": ip},
                    ]
                }
            }
            for index, ip in enumerate(node_ips)
        ]
    }
    kubectl = tmp_path / "kubectl"
    record_args = f'printf "%s\\n" "$*" > "{args_file}"\n' if args_file is not None else ""
    kubectl.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        f"{record_args}"
        f"cat <<'JSON'\n{json.dumps(payload)}\nJSON\n",
        encoding="utf-8",
    )
    kubectl.chmod(0o755)
    return kubectl


def _write_fake_ip(tmp_path: Path, mgmt_ip: str, prefix: int) -> Path:
    ip_script = tmp_path / "ip"
    ip_script.write_text(
        f"#!/usr/bin/env bash\n"
        f'if [[ "$*" == "-o -f inet addr show" ]]; then\n'
        f"  echo '2: eth0    inet {mgmt_ip}/{prefix} brd {mgmt_ip.rsplit('.', 1)[0]}.255 scope global eth0'\n"
        f"fi\n",
        encoding="utf-8",
    )
    ip_script.chmod(0o755)
    return ip_script


def _run_sync(tmp_path: Path, env_file: Path, node_ips: list[str]) -> str:
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("fake\n", encoding="utf-8")
    kubectl = _write_fake_kubectl(tmp_path, node_ips)
    env = {
        **os.environ,
        "KUBECTL_BIN": str(kubectl),
        "KUBECONFIG": str(kubeconfig),
    }
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--env-file",
            str(env_file),
            "--workspace-root",
            str(tmp_path),
            "--skip-firewall",
            "--skip-restart",
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stderr


def test_manager_api_defaults_do_not_trust_broad_lan_ranges():
    for path in [
        REPO_ROOT / ".env.example",
        REPO_ROOT / "docker-compose.yml",
        REPO_ROOT / "scripts" / "start-manager.sh",
        REPO_ROOT / "scripts" / "manager" / "configure-manager-api-firewall.sh",
        REPO_ROOT / "manager-api" / "src" / "lib" / "source-allowlist.js",
    ]:
        assert "192.168.0.0/16" not in path.read_text(encoding="utf-8")


def test_sync_manager_api_node_allowlist_adds_talos_node_32s(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\n", encoding="utf-8")

    _run_sync(tmp_path, env_file, ["192.168.2.234", "192.168.2.242"])

    text = env_file.read_text(encoding="utf-8")
    assert (f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS},192.168.2.234/32,192.168.2.242/32") in text
    assert "# BEGIN TWINBOX MANAGER API NODE ALLOWLIST" in text
    assert "# TWINBOX_MANAGER_API_NODE_CIDRS=192.168.2.234/32,192.168.2.242/32" in text


def test_sync_manager_api_node_allowlist_preserves_manual_cidrs(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS},203.0.113.8/32\n",
        encoding="utf-8",
    )

    _run_sync(tmp_path, env_file, ["192.168.2.234"])

    text = env_file.read_text(encoding="utf-8")
    assert (f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS},203.0.113.8/32,192.168.2.234/32") in text


def test_sync_manager_api_node_allowlist_replaces_old_managed_block(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        f"""MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS},203.0.113.8/32,192.168.2.100/32

# BEGIN TWINBOX MANAGER API NODE ALLOWLIST
# Managed by scripts/manager/sync-manager-api-node-allowlist.sh; do not edit this block.
# TWINBOX_MANAGER_API_NODE_CIDRS=192.168.2.100/32
# END TWINBOX MANAGER API NODE ALLOWLIST
""",
        encoding="utf-8",
    )

    _run_sync(tmp_path, env_file, ["192.168.2.234", "192.168.2.242"])

    text = env_file.read_text(encoding="utf-8")
    assert "192.168.2.100/32" not in text
    assert text.count("# BEGIN TWINBOX MANAGER API NODE ALLOWLIST") == 1
    assert (
        f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS},203.0.113.8/32,192.168.2.234/32,192.168.2.242/32"
    ) in text


def test_sync_manager_api_node_allowlist_missing_kubeconfig_is_noop(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\n", encoding="utf-8")
    missing_kubeconfig = tmp_path / "missing-kubeconfig"

    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--env-file",
            str(env_file),
            "--workspace-root",
            str(tmp_path),
            "--kubeconfig",
            str(missing_kubeconfig),
            "--skip-firewall",
            "--skip-restart",
        ],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=True,
    )

    assert "kubeconfig not found" in result.stderr
    assert env_file.read_text(encoding="utf-8") == f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\n"


def test_sync_manager_api_node_allowlist_adds_management_lan_cidr(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\n", encoding="utf-8")

    _write_fake_ip(tmp_path, "203.0.113.5", 24)
    kubectl = _write_fake_kubectl(tmp_path, ["192.168.2.234"])
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("fake\n", encoding="utf-8")

    env = {
        **os.environ,
        "KUBECTL_BIN": str(kubectl),
        "KUBECONFIG": str(kubeconfig),
        "MANAGEMENT_VM_IP": "203.0.113.5",
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
    }
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--env-file",
            str(env_file),
            "--workspace-root",
            str(tmp_path),
            "--skip-firewall",
            "--skip-restart",
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )

    assert "management VM LAN CIDR" in result.stderr
    text = env_file.read_text(encoding="utf-8")
    assert "203.0.113.0/24" in text
    assert "192.168.2.234/32" in text


def test_sync_manager_api_node_allowlist_reads_management_ip_from_env_file(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\nMANAGEMENT_VM_IP=203.0.113.5\n",
        encoding="utf-8",
    )

    _write_fake_ip(tmp_path, "203.0.113.5", 24)
    kubectl = _write_fake_kubectl(tmp_path, [])
    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("fake\n", encoding="utf-8")

    env = {
        **os.environ,
        "KUBECTL_BIN": str(kubectl),
        "KUBECONFIG": str(kubeconfig),
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
    }
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--env-file",
            str(env_file),
            "--workspace-root",
            str(tmp_path),
            "--skip-firewall",
            "--skip-restart",
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )

    assert "management VM LAN CIDR" in result.stderr
    text = env_file.read_text(encoding="utf-8")
    assert f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS},203.0.113.0/24" in text
    assert "# BEGIN TWINBOX MANAGER API NODE ALLOWLIST" not in text


def test_sync_manager_api_node_allowlist_uses_host_runtime_env_by_default(tmp_path):
    host_runtime_dir = tmp_path / "host" / "opt" / "twinbox"
    host_runtime_dir.mkdir(parents=True)
    env_file = host_runtime_dir / ".env"
    env_file.write_text(f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\n", encoding="utf-8")

    kubeconfig = tmp_path / "kubeconfig"
    kubeconfig.write_text("fake\n", encoding="utf-8")
    kubectl = _write_fake_kubectl(tmp_path, ["192.168.2.234"])

    env = {
        **os.environ,
        "KUBECTL_BIN": str(kubectl),
        "KUBECONFIG": str(kubeconfig),
        "TWINBOX_HOST_RUNTIME_DIR": str(host_runtime_dir),
    }
    subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--skip-firewall",
            "--skip-restart",
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )

    text = env_file.read_text(encoding="utf-8")
    assert "192.168.2.234/32" in text


def test_sync_manager_api_node_allowlist_discovers_cluster_kubeconfig(tmp_path):
    env_file = tmp_path / ".env"
    bootstrap_dir = tmp_path / "bootstrap"
    kubeconfig = bootstrap_dir / "secrets" / "cluster" / "prd" / "kubeconfig" / "kubeconfig"
    kubeconfig.parent.mkdir(parents=True)
    kubeconfig.write_text("fake\n", encoding="utf-8")
    env_file.write_text(
        f"MANAGER_API_TRUSTED_CIDRS={BASE_CIDRS}\nTWINBOX_BOOTSTRAP_DIR={bootstrap_dir}\n",
        encoding="utf-8",
    )
    args_file = tmp_path / "kubectl.args"
    kubectl = _write_fake_kubectl(tmp_path, ["192.168.2.242"], args_file=args_file)

    env = {
        **os.environ,
        "KUBECTL_BIN": str(kubectl),
    }
    env.pop("KUBECONFIG", None)
    env.pop("KUBECONFIG_FILE", None)

    subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--env-file",
            str(env_file),
            "--workspace-root",
            str(tmp_path),
            "--skip-firewall",
            "--skip-restart",
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )

    assert f"--kubeconfig {kubeconfig}" in args_file.read_text(encoding="utf-8")
    assert "192.168.2.242/32" in env_file.read_text(encoding="utf-8")
