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
            args = sys.argv[1:]
            entry = {{"cmd": "{name}", "args": args}}

            if "{name}" == "scp" and os.environ.get("WIZARD_DEV_CAPTURE_UPLOAD") == "1":
                source_path = Path(args[1])
                entry["uploaded_content"] = source_path.read_text(encoding="utf-8")

            with log_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry) + "\\n")

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


def _write_fake_git_cmd(bin_dir: Path) -> None:
    script = bin_dir / "git"
    script.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import os
            import sys

            args = sys.argv[1:]
            if args[:2] == ["-C", os.environ["WIZARD_DEV_REPO_ROOT"]]:
                args = args[2:]

            if args == ["rev-parse", "--is-inside-work-tree"]:
                print("true")
                sys.exit(0)
            if args == ["fetch", "--quiet", "origin", "main:refs/remotes/origin/main"]:
                sys.exit(0)
            if args == ["show", "origin/main:wizard/setup-wizard.sh"]:
                print(os.environ["WIZARD_DEV_FAKE_ORIGIN_WIZARD"], end="")
                sys.exit(0)
            if args == ["rev-parse", "origin/main"]:
                print(os.environ["WIZARD_DEV_FAKE_ORIGIN_SHA"])
                sys.exit(0)
            if args == ["rev-parse", "HEAD"]:
                print(os.environ.get("WIZARD_DEV_FAKE_HEAD_SHA", os.environ["WIZARD_DEV_FAKE_ORIGIN_SHA"]))
                sys.exit(0)
            if len(args) == 4 and args[:3] == ["log", "-1", "--format=%s"]:
                print(os.environ.get("WIZARD_DEV_FAKE_COMMIT_SUBJECT", "fix: publishable commit"))
                sys.exit(0)

            print(f"unexpected git args: {args}", file=sys.stderr)
            sys.exit(2)
            """
        ),
        encoding="utf-8",
    )
    script.chmod(0o755)


def _write_fake_curl_cmd(bin_dir: Path) -> None:
    script = bin_dir / "curl"
    script.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import os
            import sys

            url = sys.argv[-1]
            if "ghcr.io/token" in url:
                print('{"token":"test-token"}')
                sys.exit(0)
            if "/manifests/" in url:
                if os.environ.get("WIZARD_DEV_FAIL_MANIFESTS") == "1":
                    sys.exit(1)
                sys.exit(0)
            if "api.github.com" in url:
                conclusion = os.environ.get("WIZARD_DEV_FAKE_CI_CONCLUSION")
                runs = []
                if conclusion:
                    runs.append({"name": "Publish Docker Images", "conclusion": conclusion})
                print(json.dumps({"workflow_runs": runs}))
                sys.exit(0)

            print(f"unexpected curl url: {url}", file=sys.stderr)
            sys.exit(2)
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
            "WIZARD_DEV_SKIP_IMAGE_TAG_SYNC": "1",
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
            "chmod +x '/root/twinbox-dev/setup-wizard.sh' && TERM=xterm-256color bash '/root/twinbox-dev/setup-wizard.sh'",
        ],
    }
    assert "Uploading wizard to" in proc.stdout
    assert "Running wizard as root on" in proc.stdout
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
        "chmod +x '/tmp/wizard-dev/setup-wizard.sh' && TERM=xterm-256color bash '/tmp/wizard-dev/setup-wizard.sh'",
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
        "chmod +x '/root/twinbox-dev/setup-wizard.sh' && TERM=xterm-256color bash -x '/root/twinbox-dev/setup-wizard.sh'",
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
            "WIZARD_DEV_SKIP_IMAGE_TAG_SYNC": "1",
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


def test_wizard_dev_run_uploads_origin_main_wizard_with_matching_published_image_tag(
    tmp_path: Path,
):
    config_path = tmp_path / ".env.wizard.local"
    config_path.write_text(
        'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\nWIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n',
        encoding="utf-8",
    )
    bin_dir, log_path, ssh_count_path = _prepare_fake_remote_tools(tmp_path)
    _write_fake_git_cmd(bin_dir)
    _write_fake_curl_cmd(bin_dir)

    origin_wizard = textwrap.dedent(
        """\
        #!/usr/bin/env bash
        TWINBOX_IMAGE_TAG="sha-1111111"
        echo origin-main-marker
        """
    )
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env.get('PATH', '')}",
            "WIZARD_DEV_CAPTURE_UPLOAD": "1",
            "WIZARD_DEV_CONFIG_FILE": str(config_path),
            "WIZARD_DEV_FAKE_ORIGIN_SHA": "abcdef1234567890",
            "WIZARD_DEV_FAKE_ORIGIN_WIZARD": origin_wizard,
            "WIZARD_DEV_LOG": str(log_path),
            "WIZARD_DEV_REPO_ROOT": str(REPO_ROOT),
            "WIZARD_DEV_SSH_COUNT": str(ssh_count_path),
        }
    )

    proc = subprocess.run(
        ["bash", str(RUNNER_PATH)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 0, proc.stderr
    calls = _read_remote_log(tmp_path)
    uploaded_path = calls[1]["args"][1]
    assert uploaded_path != str(REPO_ROOT / "wizard" / "setup-wizard.sh")
    assert 'TWINBOX_IMAGE_TAG="sha-abcdef1"' in calls[1]["uploaded_content"]
    assert "origin-main-marker" in calls[1]["uploaded_content"]
    assert "origin-main-marker" not in (REPO_ROOT / "wizard" / "setup-wizard.sh").read_text(
        encoding="utf-8"
    )
    assert "Uploading origin-main wizard with TWINBOX_IMAGE_TAG=sha-abcdef1" in proc.stdout
    assert "Waiting for manager images sha-abcdef1 to be published" in proc.stderr
    assert "Manager images sha-abcdef1 are published" in proc.stderr


def test_wizard_dev_run_falls_back_to_pinned_tag_when_ci_publish_failed(tmp_path: Path):
    config_path = tmp_path / ".env.wizard.local"
    config_path.write_text(
        'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\nWIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n',
        encoding="utf-8",
    )
    bin_dir, log_path, ssh_count_path = _prepare_fake_remote_tools(tmp_path)
    _write_fake_git_cmd(bin_dir)
    _write_fake_curl_cmd(bin_dir)

    origin_wizard = textwrap.dedent(
        """\
        #!/usr/bin/env bash
        TWINBOX_IMAGE_TAG="sha-1111111"
        echo origin-main-marker
        """
    )
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env.get('PATH', '')}",
            "WIZARD_DEV_CAPTURE_UPLOAD": "1",
            "WIZARD_DEV_CONFIG_FILE": str(config_path),
            "WIZARD_DEV_FAKE_CI_CONCLUSION": "failure",
            "WIZARD_DEV_FAKE_ORIGIN_SHA": "abcdef1234567890",
            "WIZARD_DEV_FAKE_ORIGIN_WIZARD": origin_wizard,
            "WIZARD_DEV_LOG": str(log_path),
            "WIZARD_DEV_REPO_ROOT": str(REPO_ROOT),
            "WIZARD_DEV_SSH_COUNT": str(ssh_count_path),
        }
    )

    proc = subprocess.run(
        ["bash", str(RUNNER_PATH)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 0, proc.stderr
    calls = _read_remote_log(tmp_path)
    assert 'TWINBOX_IMAGE_TAG="sha-1111111"' in calls[1]["uploaded_content"]
    assert "Using last published tag sha-1111111" in proc.stderr
    assert "Waiting for manager images sha-abcdef1" not in proc.stderr


def test_wizard_dev_run_falls_back_to_pinned_tag_when_images_never_published(
    tmp_path: Path,
):
    config_path = tmp_path / ".env.wizard.local"
    config_path.write_text(
        (
            'WIZARD_DEV_SSH_TARGET="root@proxmox-dev"\n'
            'WIZARD_DEV_REMOTE_DIR="/root/twinbox-dev"\n'
            'WIZARD_DEV_IMAGE_TAG_WAIT_TIMEOUT_SECONDS="1"\n'
            'WIZARD_DEV_IMAGE_TAG_WAIT_INTERVAL_SECONDS="1"\n'
        ),
        encoding="utf-8",
    )
    bin_dir, log_path, ssh_count_path = _prepare_fake_remote_tools(tmp_path)
    _write_fake_git_cmd(bin_dir)
    _write_fake_curl_cmd(bin_dir)

    origin_wizard = textwrap.dedent(
        """\
        #!/usr/bin/env bash
        TWINBOX_IMAGE_TAG="sha-1111111"
        echo origin-main-marker
        """
    )
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env.get('PATH', '')}",
            "WIZARD_DEV_CAPTURE_UPLOAD": "1",
            "WIZARD_DEV_CONFIG_FILE": str(config_path),
            "WIZARD_DEV_FAIL_MANIFESTS": "1",
            "WIZARD_DEV_FAKE_ORIGIN_SHA": "abcdef1234567890",
            "WIZARD_DEV_FAKE_ORIGIN_WIZARD": origin_wizard,
            "WIZARD_DEV_LOG": str(log_path),
            "WIZARD_DEV_REPO_ROOT": str(REPO_ROOT),
            "WIZARD_DEV_SSH_COUNT": str(ssh_count_path),
        }
    )

    proc = subprocess.run(
        ["bash", str(RUNNER_PATH)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )

    assert proc.returncode == 0, proc.stderr
    calls = _read_remote_log(tmp_path)
    assert 'TWINBOX_IMAGE_TAG="sha-1111111"' in calls[1]["uploaded_content"]
    assert "Using last published tag sha-1111111" in proc.stderr
    assert "Waiting for manager images sha-abcdef1 to be published" in proc.stderr


def test_wizard_dev_run_resolves_current_image_tag_without_mutating_checkout():
    text = RUNNER_PATH.read_text(encoding="utf-8")

    assert "resolve_wizard_image_tag()" in text
    assert "refresh_origin_main()" in text
    assert "write_origin_wizard_source()" in text
    assert "wait_for_manager_images()" in text
    assert "manager_images_exist()" in text
    assert 'write_wizard_with_image_tag "$source_path" "$image_tag"' in text
    assert 'scp -q "${WIZARD_UPLOAD_PATH}"' in text
    assert 'git -C "$REPO_ROOT" merge --ff-only' not in text
    assert "Using last published tag ${source_tag}" in text
