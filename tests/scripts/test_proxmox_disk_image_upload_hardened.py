import shlex
import subprocess
import tempfile
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"


def test_talos_disk_image_upload_uses_import_content_and_continues_after_failure():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                file_size_bytes() {{
                  wc -c < "$1" | tr -d '[:space:]'
                }}

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=1
                export PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES=10
                export PROXMOX_PORT=8006
                export PROXMOX_USER=root@pam
                export PROXMOX_PASSWORD=secret
                export TF_VAR_proxmox_endpoint=https://pve1.local.westermanonline.com:8006
                IMAGE_PATH="$PWD/talos-cluster.img"
                printf 'talos-image-content\\n' > "$IMAGE_PATH"
                IMAGE_SIZE="$(wc -c < "$IMAGE_PATH" | tr -d '[:space:]')"
                UPLOAD_MARKER_FILE="$PWD/node-a-uploaded"
                rm -f "$UPLOAD_MARKER_FILE"

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^proxmox_api_login\\(\\) \\{{/ {{ emit = 1 }}
                  /^remove_legacy_talos_file_state\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                FAKE_CLUSTER_STATUS='{{"data":[{{"type":"node","name":"node-a","ip":"192.168.2.91"}},{{"type":"node","name":"node-b","ip":"192.168.2.92"}}]}}'

                curl() {{
                  local output_file=""
                  local url="${{@: -1}}"
                  local arg=""
                  local prev=""

                  for arg in "$@"; do
                    if [[ "$prev" == "--output" ]]; then
                      output_file="$arg"
                    fi
                    if [[ "$prev" == "--form" || "$prev" == "--header" ]]; then
                      log "CURL_${{prev#--}}=$arg"
                    fi
                    prev="$arg"
                  done

                  case "$url" in
                    */access/ticket)
                      printf '%s\\n' '{{"data":{{"ticket":"ticket","CSRFPreventionToken":"csrf"}}}}'
                      return 0
                      ;;
                    */cluster/status)
                      printf '%s\\n' "$FAKE_CLUSTER_STATUS"
                      return 0
                      ;;
                    */storage/local/content)
                      case "$url" in
                        *192.168.2.91*)
                          if [[ -f "$UPLOAD_MARKER_FILE" ]]; then
                            printf '{{"data":[{{"volid":"local:import/talos-cluster.img","content":"import","size":%s}}]}}\\n' "$IMAGE_SIZE"
                          else
                            printf '%s\\n' '{{"data":[]}}'
                          fi
                          return 0
                          ;;
                        *192.168.2.92*)
                          printf '%s\\n' '{{"data":[]}}'
                          return 0
                          ;;
                      esac
                      ;;
                    */storage/local/status)
                      printf '%s\\n' '{{"data":{{"avail":10737418240}}}}'
                      return 0
                      ;;
                    */storage/local/upload)
                      log "UPLOAD_URL=$url"
                      if [[ "$url" == *192.168.2.92* ]]; then
                        return 52
                      fi
                      if [[ -n "$output_file" ]]; then
                        printf '%s\\n' '{{"data":"ok"}}' >"$output_file"
                      fi
                      if [[ "$url" == *192.168.2.91* ]]; then
                        : > "$UPLOAD_MARKER_FILE"
                      fi
                      printf '200\\n'
                      return 0
                      ;;
                  esac

                  printf 'unexpected curl url: %s\\n' "$url" >&2
                  return 1
                }}

                set +e
                upload_talos_image_to_nodes "$IMAGE_PATH" "talos-cluster.img" '["node-b","node-a"]'
                status=$?
                set -e

                printf 'STATUS=%s\\n' "$status" >> "$LOG_FILE"
                """
            ),
            encoding="utf-8",
        )
        harness.chmod(0o755)

        proc = subprocess.run(
            ["bash", str(harness)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr

        log_text = log_file.read_text(encoding="utf-8")
        assert (
            "Uploading Talos disk image directly to node-b/local via https://192.168.2.92:8006"
            in log_text
        )
        assert (
            "Uploading Talos disk image directly to node-a/local via https://192.168.2.91:8006"
            in log_text
        )
        assert (
            "UPLOAD_URL=https://192.168.2.92:8006/api2/json/nodes/node-b/storage/local/upload"
            in log_text
        )
        assert (
            "UPLOAD_URL=https://192.168.2.91:8006/api2/json/nodes/node-a/storage/local/upload"
            in log_text
        )
        assert "CURL_header=Expect:" in log_text
        assert "CURL_form=content=import" in log_text
        assert "Proxmox file datastore node-b/local has 10737418240 bytes available" in log_text
        assert (
            "ERROR: Talos disk image upload to node-b/local failed after 1 attempts (curl exit 52): no response body"
            in log_text
        )
        assert (
            "Verified Talos disk image on node-a/local: local:import/talos-cluster.img" in log_text
        )
        assert "Talos disk image upload summary: succeeded=node-a; failed=node-b" in log_text
        assert (
            "Talos disk image upload failure: Talos disk image upload to node-b/local failed after 1 attempts (curl exit 52): no response body"
            in log_text
        )
        assert "STATUS=1" in log_text


def test_talos_disk_image_existing_import_must_match_local_size():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                file_size_bytes() {{
                  wc -c < "$1" | tr -d '[:space:]'
                }}

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=1
                export PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES=10
                export PROXMOX_PORT=8006
                export PROXMOX_USER=root@pam
                export PROXMOX_PASSWORD=secret
                export TF_VAR_proxmox_endpoint=https://pve1.local.westermanonline.com:8006
                IMAGE_PATH="$PWD/talos-cluster.img"
                printf 'talos-image-content\\n' > "$IMAGE_PATH"
                IMAGE_SIZE="$(wc -c < "$IMAGE_PATH" | tr -d '[:space:]')"

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^proxmox_api_login\\(\\) \\{{/ {{ emit = 1 }}
                  /^remove_legacy_talos_file_state\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                FAKE_CLUSTER_STATUS='{{"data":[{{"type":"node","name":"node-a","ip":"192.168.2.91"}}]}}'

                curl() {{
                  local url="${{@: -1}}"

                  case "$url" in
                    */access/ticket)
                      printf '%s\\n' '{{"data":{{"ticket":"ticket","CSRFPreventionToken":"csrf"}}}}'
                      return 0
                      ;;
                    */cluster/status)
                      printf '%s\\n' "$FAKE_CLUSTER_STATUS"
                      return 0
                      ;;
                    */storage/local/content)
                      printf '{{"data":[{{"volid":"local:import/talos-cluster.img","content":"import","size":%s}}]}}\\n' "$IMAGE_SIZE"
                      return 0
                      ;;
                    */storage/local/status|*/storage/local/upload)
                      log "UNEXPECTED_URL=$url"
                      return 1
                      ;;
                  esac

                  printf 'unexpected curl url: %s\\n' "$url" >&2
                  return 1
                }}

                upload_talos_image_to_nodes "$IMAGE_PATH" "talos-cluster.img" '["node-a"]'
                """
            ),
            encoding="utf-8",
        )
        harness.chmod(0o755)

        proc = subprocess.run(
            ["bash", str(harness)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr

        log_text = log_file.read_text(encoding="utf-8")
        assert "Talos disk image already present on node-a/local: talos-cluster.img" in log_text
        assert "UNEXPECTED_URL=" not in log_text


def test_talos_disk_image_verify_waits_for_uploaded_size_to_settle():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                file_size_bytes() {{
                  wc -c < "$1" | tr -d '[:space:]'
                }}

                sleep() {{
                  log "SLEEP=$1"
                }}

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=24
                export PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES=10
                export PROXMOX_PORT=8006
                export PROXMOX_USER=root@pam
                export PROXMOX_PASSWORD=secret
                export TF_VAR_proxmox_endpoint=https://pve1.local.westermanonline.com:8006
                IMAGE_PATH="$PWD/talos-cluster.img"
                printf 'talos-image-content\\n' > "$IMAGE_PATH"
                IMAGE_SIZE="$(wc -c < "$IMAGE_PATH" | tr -d '[:space:]')"
                UPLOAD_MARKER_FILE="$PWD/node-a-uploaded"
                VERIFY_COUNT_FILE="$PWD/verify-count"
                rm -f "$UPLOAD_MARKER_FILE" "$VERIFY_COUNT_FILE"

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^proxmox_api_login\\(\\) \\{{/ {{ emit = 1 }}
                  /^remove_legacy_talos_file_state\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                FAKE_CLUSTER_STATUS='{{"data":[{{"type":"node","name":"node-a","ip":"192.168.2.91"}}]}}'

                curl() {{
                  local output_file=""
                  local url="${{@: -1}}"
                  local arg=""
                  local prev=""

                  for arg in "$@"; do
                    if [[ "$prev" == "--output" ]]; then
                      output_file="$arg"
                    fi
                    prev="$arg"
                  done

                  case "$url" in
                    */access/ticket)
                      printf '%s\\n' '{{"data":{{"ticket":"ticket","CSRFPreventionToken":"csrf"}}}}'
                      return 0
                      ;;
                    */cluster/status)
                      printf '%s\\n' "$FAKE_CLUSTER_STATUS"
                      return 0
                      ;;
                    */storage/local/content)
                      if [[ ! -f "$UPLOAD_MARKER_FILE" ]]; then
                        printf '%s\\n' '{{"data":[]}}'
                        return 0
                      fi
                      count=1
                      if [[ -f "$VERIFY_COUNT_FILE" ]]; then
                        count=$(( $(cat "$VERIFY_COUNT_FILE") + 1 ))
                      fi
                      printf '%s' "$count" > "$VERIFY_COUNT_FILE"
                      if [[ "$count" -lt 20 ]]; then
                        printf '%s\\n' '{{"data":[{{"volid":"local:import/talos-cluster.img","content":"import","size":1}}]}}'
                      else
                        printf '{{"data":[{{"volid":"local:import/talos-cluster.img","content":"import","size":%s}}]}}\\n' "$IMAGE_SIZE"
                      fi
                      return 0
                      ;;
                    */storage/local/status)
                      printf '%s\\n' '{{"data":{{"avail":10737418240}}}}'
                      return 0
                      ;;
                    */storage/local/upload)
                      log "UPLOAD_URL=$url"
                      if [[ -n "$output_file" ]]; then
                        printf '%s\\n' '{{"data":"ok"}}' >"$output_file"
                      fi
                      : > "$UPLOAD_MARKER_FILE"
                      printf '200\\n'
                      return 0
                      ;;
                  esac

                  printf 'unexpected curl url: %s\\n' "$url" >&2
                  return 1
                }}

                upload_talos_image_to_nodes "$IMAGE_PATH" "talos-cluster.img" '["node-a"]'
                """
            ),
            encoding="utf-8",
        )
        harness.chmod(0o755)

        proc = subprocess.run(
            ["bash", str(harness)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr

        log_text = log_file.read_text(encoding="utf-8")
        assert (
            "Talos disk image on node-a/local is 1 bytes, expected 20; retrying in 1s" in log_text
        )
        assert "SLEEP=1" in log_text
        assert "SLEEP=10" in log_text
        assert (
            "Verified Talos disk image on node-a/local: local:import/talos-cluster.img" in log_text
        )
        assert "failed=none" in log_text


def test_talos_disk_image_wrong_size_fails_before_upload():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                file_size_bytes() {{
                  wc -c < "$1" | tr -d '[:space:]'
                }}

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=1
                export PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES=10
                export PROXMOX_PORT=8006
                export PROXMOX_USER=root@pam
                export PROXMOX_PASSWORD=secret
                export TF_VAR_proxmox_endpoint=https://pve1.local.westermanonline.com:8006
                IMAGE_PATH="$PWD/talos-cluster.img"
                printf 'talos-image-content\\n' > "$IMAGE_PATH"

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^proxmox_api_login\\(\\) \\{{/ {{ emit = 1 }}
                  /^remove_legacy_talos_file_state\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                FAKE_CLUSTER_STATUS='{{"data":[{{"type":"node","name":"node-a","ip":"192.168.2.91"}}]}}'

                curl() {{
                  local url="${{@: -1}}"

                  case "$url" in
                    */access/ticket)
                      printf '%s\\n' '{{"data":{{"ticket":"ticket","CSRFPreventionToken":"csrf"}}}}'
                      return 0
                      ;;
                    */cluster/status)
                      printf '%s\\n' "$FAKE_CLUSTER_STATUS"
                      return 0
                      ;;
                    */storage/local/content)
                      printf '%s\\n' '{{"data":[{{"volid":"local:import/talos-cluster.img","content":"import","size":1}}]}}'
                      return 0
                      ;;
                    */storage/local/upload)
                      log "UNEXPECTED_UPLOAD=$url"
                      return 1
                      ;;
                  esac

                  printf 'unexpected curl url: %s\\n' "$url" >&2
                  return 1
                }}

                set +e
                upload_talos_image_to_nodes "$IMAGE_PATH" "talos-cluster.img" '["node-a"]'
                status=$?
                set -e

                printf 'STATUS=%s\\n' "$status" >> "$LOG_FILE"
                """
            ),
            encoding="utf-8",
        )
        harness.chmod(0o755)

        proc = subprocess.run(
            ["bash", str(harness)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr

        log_text = log_file.read_text(encoding="utf-8")
        assert "has unexpected size" in log_text
        assert "expected=20 bytes, actual=1 bytes" in log_text
        assert "UNEXPECTED_UPLOAD=" not in log_text
        assert "STATUS=1" in log_text


def test_talos_disk_image_upload_requires_file_datastore_free_space():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                file_size_bytes() {{
                  wc -c < "$1" | tr -d '[:space:]'
                }}

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=1
                export PROXMOX_IMPORT_FREE_SPACE_BUFFER_BYTES=1000
                export PROXMOX_PORT=8006
                export PROXMOX_USER=root@pam
                export PROXMOX_PASSWORD=secret
                export TF_VAR_proxmox_endpoint=https://pve1.local.westermanonline.com:8006
                IMAGE_PATH="$PWD/talos-cluster.img"
                printf 'talos-image-content\\n' > "$IMAGE_PATH"

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^proxmox_api_login\\(\\) \\{{/ {{ emit = 1 }}
                  /^remove_legacy_talos_file_state\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                FAKE_CLUSTER_STATUS='{{"data":[{{"type":"node","name":"node-a","ip":"192.168.2.91"}}]}}'

                curl() {{
                  local url="${{@: -1}}"

                  case "$url" in
                    */access/ticket)
                      printf '%s\\n' '{{"data":{{"ticket":"ticket","CSRFPreventionToken":"csrf"}}}}'
                      return 0
                      ;;
                    */cluster/status)
                      printf '%s\\n' "$FAKE_CLUSTER_STATUS"
                      return 0
                      ;;
                    */storage/local/content)
                      printf '%s\\n' '{{"data":[]}}'
                      return 0
                      ;;
                    */storage/local/status)
                      printf '%s\\n' '{{"data":{{"avail":10}}}}'
                      return 0
                      ;;
                    */storage/local/upload)
                      log "UNEXPECTED_UPLOAD=$url"
                      return 1
                      ;;
                  esac

                  printf 'unexpected curl url: %s\\n' "$url" >&2
                  return 1
                }}

                set +e
                upload_talos_image_to_nodes "$IMAGE_PATH" "talos-cluster.img" '["node-a"]'
                status=$?
                set -e

                printf 'STATUS=%s\\n' "$status" >> "$LOG_FILE"
                """
            ),
            encoding="utf-8",
        )
        harness.chmod(0o755)

        proc = subprocess.run(
            ["bash", str(harness)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

        assert proc.returncode == 0, proc.stderr

        log_text = log_file.read_text(encoding="utf-8")
        assert "has insufficient free space for Talos disk image upload" in log_text
        assert "available=10 bytes" in log_text
        assert "required=1020 bytes" in log_text
        assert "UNEXPECTED_UPLOAD=" not in log_text
        assert "STATUS=1" in log_text
