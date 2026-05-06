import shlex
import subprocess
import tempfile
import textwrap
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"


def test_talos_iso_upload_uses_direct_node_endpoints_and_continues_after_failure():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=1
                export PROXMOX_PORT=8006
                export PROXMOX_USER=root@pam
                export PROXMOX_PASSWORD=secret
                export TF_VAR_proxmox_endpoint=https://pve1.local.westermanonline.com:8006
                UPLOAD_MARKER_FILE="$PWD/node-a-uploaded"
                rm -f "$UPLOAD_MARKER_FILE"

                HELPERS_FILE="$(mktemp)"
                sed -n '173,481p' {shlex.quote(str(APPLY_CLUSTER_SCRIPT))} >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                FAKE_CLUSTER_STATUS='{{"data":[{{"type":"node","name":"node-a","ip":"192.168.2.91"}},{{"type":"node","name":"node-b","ip":"192.168.2.92"}}]}}'
                UPLOAD_URLS=()

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
                      printf '%s\n' '{{"data":{{"ticket":"ticket","CSRFPreventionToken":"csrf"}}}}'
                      return 0
                      ;;
                    */cluster/status)
                      printf '%s\n' "$FAKE_CLUSTER_STATUS"
                      return 0
                      ;;
                    */storage/local/content)
                      case "$url" in
                        *192.168.2.91*)
                          if [[ -f "$UPLOAD_MARKER_FILE" ]]; then
                            printf '%s\n' '{{"data":[{{"volid":"local:iso/talos.iso","content":"iso"}}]}}'
                          else
                            printf '%s\n' '{{"data":[]}}'
                          fi
                          return 0
                          ;;
                        *192.168.2.92*)
                          printf '%s\n' '{{"data":[]}}'
                          return 0
                          ;;
                      esac
                      ;;
                    */storage/local/upload)
                      UPLOAD_URLS+=("$url")
                      log "UPLOAD_URL=$url"
                      if [[ "$url" == *192.168.2.92* ]]; then
                        return 52
                      fi
                      if [[ -n "$output_file" ]]; then
                        printf '%s\n' '{{"data":"ok"}}' >"$output_file"
                      fi
                      if [[ "$url" == *192.168.2.91* ]]; then
                        : > "$UPLOAD_MARKER_FILE"
                      fi
                      printf '200\n'
                      return 0
                      ;;
                  esac

                  printf 'unexpected curl url: %s\n' "$url" >&2
                  return 1
                }}

                set +e
                upload_talos_image_to_nodes "/tmp/talos.iso" "talos.iso" '["node-b","node-a"]'
                status=$?
                set -e

                printf 'STATUS=%s\n' "$status" >> "$LOG_FILE"
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
        assert "Uploading Talos ISO directly to node-b/local via https://192.168.2.92:8006" in log_text
        assert "Uploading Talos ISO directly to node-a/local via https://192.168.2.91:8006" in log_text
        assert "UPLOAD_URL=https://192.168.2.92:8006/api2/json/nodes/node-b/storage/local/upload" in log_text
        assert "UPLOAD_URL=https://192.168.2.91:8006/api2/json/nodes/node-a/storage/local/upload" in log_text
        assert "ERROR: Talos ISO upload to node-b/local failed after 1 attempts (curl exit 52): no response body" in log_text
        assert "Verified Talos ISO on node-a/local: local:iso/talos.iso" in log_text
        assert "Talos ISO upload summary: succeeded=node-a; failed=node-b" in log_text
        assert "Talos ISO upload failure: Talos ISO upload to node-b/local failed after 1 attempts (curl exit 52): no response body" in log_text
        assert "STATUS=1" in log_text
