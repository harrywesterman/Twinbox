import json
import os
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER_PATH = REPO_ROOT / "scripts" / "wizard-dev-run.sh"


def _write_fake_remote_cmd(bin_dir: Path, name: str) -> None:
    script = bin_dir / name
    script.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import json
            import os
            import sys
            from pathlib import Path

            log_path = Path(os.environ["WIZARD_DEV_LOG"])
            with log_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({{"cmd": "{name}", "args": sys.argv[1:]}}) + "\\n")

            if "{name}" == "ssh":
                count_path = Path(os.environ["WIZARD_DEV_SSH_COUNT"])
                count = int(count_path.read_text(encoding="utf-8")) if count_path.exists() else 0
                count += 1
                count_path.write_text(str(count), encoding="utf-8")
                fail_on = os.environ.get("WIZARD_DEV_FAIL_SSH_CALL")
                if fail_on and count == int(fail_on):
                    sys.exit(23)
            """
        ),
        encoding="utf-8",
    )
    script.chmod(0o755)


def _prepare_fake_remote_tools(tmp_path: Path) -> tuple[Path, Path, Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_fake_remote_cmd(bin_dir, "ssh")
    _write_fake_remote_cmd(bin_dir, "scp")
    log_path = tmp_path / "remote-log.jsonl"
    ssh_count_path = tmp_path / "ssh-count.txt"
    return bin_dir, log_path, ssh_count_path


def _run_runner(
    tmp_path: Path, args: list[str], config_text: str = ""
) -> subprocess.CompletedProcess[str]:
    config_path = tmp_path / ".env.wizard.local"
    config_path.write_text(config_text, encoding="utf-8")
    bin_dir, log_path, ssh_count_path = _prepare_fake_remote_tools(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env.get('PATH', '')}",
            "WIZARD_DEV_CONFIG_FILE": str(config_path),
            "WIZARD_DEV_LOG": str(log_path),
            "WIZARD_DEV_SSH_COUNT": str(ssh_count_path),
        }
    )
    return subprocess.run(
        ["bash", str(RUNNER_PATH), *args],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )


def _read_remote_log(tmp_path: Path) -> list[dict[str, object]]:
    log_path = tmp_path / "remote-log.jsonl"
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]


def test_wizard_dev_run_loads_default_local_config_and_uses_tty_remote_run(tmp_path: Path):
    proc = _run_runner(
        tmp_path,
        [],
        config_text=(
            'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\nWIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n'
        ),
    )

    assert proc.returncode == 0, proc.stderr
    calls = _read_remote_log(tmp_path)

    assert calls[0] == {
        "cmd": "ssh",
        "args": ["-n", "root@proxmox-dev", "mkdir -p '/root/twinbox-dev'"],
    }
    assert calls[1] == {
        "cmd": "scp",
        "args": [
            "-q",
            str(REPO_ROOT / "wizard" / "setup-wizard.sh"),
            "root@proxmox-dev:/root/twinbox-dev/setup-wizard.sh",
        ],
    }
    assert calls[2] == {
        "cmd": "ssh",
        "args": [
            "-tt",
            "root@proxmox-dev",
            "sudo chmod +x '/root/twinbox-dev/setup-wizard.sh' && sudo TERM=xterm-256color bash '/root/twinbox-dev/setup-wizard.sh'",
        ],
    }
    assert "Uploading wizard to" in proc.stdout
    assert "Running wizard as root via sudo on" in proc.stdout
    assert "Remote wizard copy: root@proxmox-dev:/root/twinbox-dev/setup-wizard.sh" in proc.stdout


def test_wizard_dev_run_cli_overrides_config_file_defaults(tmp_path: Path):
    proc = _run_runner(
        tmp_path,
        ["--target", "root@override-host", "--remote-dir", "/tmp/wizard-dev"],
        config_text=(
            'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\nWIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n'
        ),
    )

    assert proc.returncode == 0, proc.stderr
    calls = _read_remote_log(tmp_path)
    assert calls[0]["args"] == ["-n", "root@override-host", "mkdir -p '/tmp/wizard-dev'"]
    assert calls[1]["args"] == [
        "-q",
        str(REPO_ROOT / "wizard" / "setup-wizard.sh"),
        "root@override-host:/tmp/wizard-dev/setup-wizard.sh",
    ]
    assert calls[2]["args"] == [
        "-tt",
        "root@override-host",
        "sudo chmod +x '/tmp/wizard-dev/setup-wizard.sh' && sudo TERM=xterm-256color bash '/tmp/wizard-dev/setup-wizard.sh'",
    ]


def test_wizard_dev_run_debug_flag_uses_bash_x_for_remote_execution(tmp_path: Path):
    proc = _run_runner(
        tmp_path,
        ["--debug"],
        config_text=(
            'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\nWIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n'
        ),
    )

    assert proc.returncode == 0, proc.stderr
    calls = _read_remote_log(tmp_path)
    assert calls[2]["args"] == [
        "-tt",
        "root@proxmox-dev",
        "sudo chmod +x '/root/twinbox-dev/setup-wizard.sh' && sudo TERM=xterm-256color bash -x '/root/twinbox-dev/setup-wizard.sh'",
    ]


def test_wizard_dev_run_requires_target_when_no_config_or_override_is_present(tmp_path: Path):
    proc = _run_runner(tmp_path, [])

    assert proc.returncode != 0
    assert "WIZARD_DEV_SSH_TARGET" in proc.stderr
    assert ".env.wizard.local" not in proc.stderr


def test_wizard_dev_run_reports_retained_remote_copy_when_remote_execution_fails(tmp_path: Path):
    config_path = tmp_path / ".env.wizard.local"
    config_path.write_text(
        'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\nWIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n',
        encoding="utf-8",
    )
    bin_dir, log_path, ssh_count_path = _prepare_fake_remote_tools(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env.get('PATH', '')}",
            "WIZARD_DEV_CONFIG_FILE": str(config_path),
            "WIZARD_DEV_LOG": str(log_path),
            "WIZARD_DEV_SSH_COUNT": str(ssh_count_path),
            "WIZARD_DEV_FAIL_SSH_CALL": "2",
        }
    )

    proc = subprocess.run(
        ["bash", str(RUNNER_PATH)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 23
    assert (
        "Remote wizard copy retained at root@proxmox-dev:/root/twinbox-dev/setup-wizard.sh"
        in proc.stderr
    )
