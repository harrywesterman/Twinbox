import shlex
import subprocess
import tempfile
import textwrap
from pathlib import Path


def test_talos_iso_upload_continues_after_one_node_failure():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "upload.log"
        harness = root / "harness.sh"

        harness.write_text(
            textwrap.dedent(
                """
                #!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE=__LOG_FILE__
                : > "$LOG_FILE"

                log() {
                  printf '%s\n' "$*" >> "$LOG_FILE"
                }

                fail() {
                  printf 'FAIL:%s\n' "$*" >> "$LOG_FILE"
                  return 1
                }

                jq() {
                  if [[ "$1" == "-r" && "$2" == ".[]" ]]; then
                    python3 -c 'import json,sys; [print(item) for item in json.load(sys.stdin)]'
                    return $?
                  fi

                  printf 'unsupported jq invocation: %s\n' "$*" >&2
                  return 127
                }

                export FILE_DATASTORE=local
                export PROXMOX_UPLOAD_MAX_ATTEMPTS=1
                export PROXMOX_VERIFY_MAX_ATTEMPTS=1

                proxmox_talos_image_present() {
                  return 1
                }

                proxmox_upload_talos_image() {
                  local node="$1"
                  local datastore="$2"

                  if [[ "$node" == "node-b" ]]; then
                    PROXMOX_TALOS_IMAGE_ERROR="Talos ISO upload to ${node}/${datastore} failed after 1 attempts (curl exit 52): no response body"
                    log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
                    return 1
                  fi

                  log "Uploaded Talos ISO to ${node}/${datastore}"
                  PROXMOX_TALOS_IMAGE_ERROR=""
                  return 0
                }

                proxmox_verify_talos_image() {
                  local node="$1"
                  local datastore="$2"

                  if [[ "$node" == "node-a" ]]; then
                    log "Verified Talos ISO on ${node}/${datastore}: ${datastore}:iso/talos.iso"
                    PROXMOX_TALOS_IMAGE_ERROR=""
                    return 0
                  fi

                  PROXMOX_TALOS_IMAGE_ERROR="Talos ISO not visible after upload on ${node}/${datastore}: ${datastore}:iso/talos.iso"
                  log "ERROR: ${PROXMOX_TALOS_IMAGE_ERROR}"
                  return 1
                }

                upload_talos_image_to_nodes() {
                  local image_path="$1"
                  local image_name="$2"
                  local nodes_json="$3"
                  local node=""
                  local success_nodes=()
                  local failed_nodes=()
                  local failure_messages=()

                  while IFS= read -r node; do
                    [[ -n "$node" ]] || continue
                    if proxmox_talos_image_present "$node" "$FILE_DATASTORE" "$image_name"; then
                      log "Talos ISO already present on ${node}/${FILE_DATASTORE}: ${image_name}"
                      success_nodes+=("$node")
                      continue
                    fi
                    log "Uploading Talos ISO to ${node}"
                    PROXMOX_TALOS_IMAGE_ERROR=""
                    if ! proxmox_upload_talos_image "$node" "$FILE_DATASTORE" "$image_path" "$image_name"; then
                      failed_nodes+=("$node")
                      failure_messages+=("${PROXMOX_TALOS_IMAGE_ERROR:-Talos ISO upload to ${node}/${FILE_DATASTORE} failed}")
                      continue
                    fi
                    PROXMOX_TALOS_IMAGE_ERROR=""
                    if ! proxmox_verify_talos_image "$node" "$FILE_DATASTORE" "$image_name"; then
                      failed_nodes+=("$node")
                      failure_messages+=("${PROXMOX_TALOS_IMAGE_ERROR:-Talos ISO verification failed for ${node}/${FILE_DATASTORE}}")
                      continue
                    fi
                    success_nodes+=("$node")
                  done < <(jq -r '.[]' <<<"$nodes_json")

                  if [[ ${#failed_nodes[@]} -gt 0 ]]; then
                    log "Talos ISO upload summary: succeeded=${success_nodes[*]:-none}; failed=${failed_nodes[*]}"
                    local failure_message=""
                    local failure=""
                    for failure in "${failure_messages[@]}"; do
                      failure_message+="${failure}"$'\n'
                    done
                    while IFS= read -r failure; do
                      [[ -n "$failure" ]] || continue
                      log "Talos ISO upload failure: ${failure}"
                    done <<<"${failure_message%$'\n'}"
                    return 1
                  fi

                  log "Talos ISO upload summary: succeeded=${success_nodes[*]:-none}; failed=none"
                }

                set +e
                upload_talos_image_to_nodes "/tmp/talos.iso" "talos.iso" '["node-b","node-a"]'
                status=$?
                set -e

                printf 'STATUS=%s\n' "$status" >> "$LOG_FILE"
                """
            )
            .replace("__LOG_FILE__", shlex.quote(str(log_file))),
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
        assert "Uploading Talos ISO to node-b" in log_text
        assert "ERROR: Talos ISO upload to node-b/local failed after 1 attempts (curl exit 52): no response body" in log_text
        assert "Uploading Talos ISO to node-a" in log_text
        assert "Verified Talos ISO on node-a/local: local:iso/talos.iso" in log_text
        assert "Talos ISO upload summary: succeeded=node-a; failed=node-b" in log_text
        assert "Talos ISO upload failure: Talos ISO upload to node-b/local failed after 1 attempts (curl exit 52): no response body" in log_text
        assert "STATUS=1" in log_text
