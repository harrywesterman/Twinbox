import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "get-talos-image-factory.sh"
PINNED_DEFAULTS = REPO_ROOT / "config" / "pinned-defaults.sh"


def test_get_talos_image_factory_builds_qemu_guest_agent_shell_output():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bin_dir = root / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)

        fake_curl = bin_dir / "curl"
        args_file = root / "curl-args.txt"
        stdin_file = root / "curl-stdin.txt"
        count_file = root / "curl-count.txt"
        fake_curl.write_text(
            f"""#!/bin/bash
set -euo pipefail
count=1
if [[ -f "{count_file}" ]]; then
  count=$(( $(cat "{count_file}") + 1 ))
fi
printf '%s' "$count" > "{count_file}"
printf '%s\\n' "$@" > "{args_file}.$count"
cat > "{stdin_file}.$count"
if printf '%s\\n' "$@" | grep -qx -- '-X' && printf '%s\\n' "$@" | grep -qx -- 'POST'; then
  printf '{{"id":"schematic123"}}'
else
  printf 'https://assets.factory.talos.dev/assets/final.iso'
fi
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"

        proc = subprocess.run(
            [
                str(SCRIPT_PATH),
                "--preset",
                "qemu-guest-agent",
                "--version",
                "v1.9.2",
                "--output",
                "shell",
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr
        assert "TALOS_IMAGE_SCHEMATIC=schematic123" in proc.stdout
        assert "TALOS_IMAGE_FACTORY_URL=https://factory.talos.dev/image/schematic123/v1.9.2/metal-amd64.iso" in proc.stdout
        assert "TALOS_IMAGE_DOWNLOAD_URL=https://assets.factory.talos.dev/assets/final.iso" in proc.stdout

        curl_args_1 = args_file.with_name("curl-args.txt.1").read_text(encoding="utf-8")
        curl_stdin_1 = stdin_file.with_name("curl-stdin.txt.1").read_text(encoding="utf-8")
        curl_args_2 = args_file.with_name("curl-args.txt.2").read_text(encoding="utf-8")
        assert "https://factory.talos.dev/schematics" in curl_args_1
        assert "POST" in curl_args_1
        assert "siderolabs/qemu-guest-agent" in curl_stdin_1
        assert "https://factory.talos.dev/image/schematic123/v1.9.2/metal-amd64.iso" in curl_args_2


def test_pinned_defaults_do_not_hardcode_a_talos_schematic():
    text = PINNED_DEFAULTS.read_text(encoding="utf-8")
    assert "PINNED_TALOS_IMAGE_SCHEMATIC" not in text
