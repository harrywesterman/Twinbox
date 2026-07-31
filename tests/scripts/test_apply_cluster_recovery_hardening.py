import shlex
import subprocess
import tempfile
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APPLY_CLUSTER_SCRIPT = REPO_ROOT / "scripts" / "manager" / "apply-cluster.sh"


def test_validate_vm_ids_allows_ids_managed_by_existing_state():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "validate.log"
        module_dir = root / "module"
        module_dir.mkdir()
        (module_dir / "terraform.tfstate").write_text(
            textwrap.dedent(
                """\
                {
                  "resources": [
                    {
                      "mode": "managed",
                      "type": "proxmox_virtual_environment_vm",
                      "name": "node",
                      "instances": [
                        {"attributes": {"vm_id": 200}},
                        {"attributes": {"vm_id": 201}},
                        {"attributes": {"vm_id": 202}}
                      ]
                    }
                  ]
                }
                """
            ),
            encoding="utf-8",
        )
        harness = root / "harness.sh"
        harness.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                work_module_dir={shlex.quote(str(module_dir))}
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^array_contains\\(\\) \\{{/ {{ emit = 1 }}
                  /^SCRIPT_DIR=/ {{ emit = 0 }}
                  /^proxmox_get_all_vm_ids\\(\\) \\{{/ {{ emit = 1 }}
                  /^validate_file_datastore_import_content\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                proxmox_get_all_vm_ids() {{
                  printf '%s\\n' 100 200 201 202 999
                }}

                validate_vm_ids_available '[{{"vmid":200}},{{"vmid":201}},{{"vmid":202}}]'
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
            "Ignoring VM IDs already managed by this cluster OpenTofu state: 200 201 202"
            in log_text
        )
        assert "All planned VM IDs are available: 200 201 202" in log_text
        assert "FAIL:" not in log_text


def test_bootstrap_cluster_retries_until_talos_reports_available():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "bootstrap.log"
        kubeconfig_file = root / "kubeconfig"
        talosconfig_file = root / "talosconfig"
        talosconfig_file.write_text("talosconfig", encoding="utf-8")
        harness = root / "harness.sh"
        harness.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail

                LOG_FILE={shlex.quote(str(log_file))}
                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                talosconfig_file={shlex.quote(str(talosconfig_file))}
                kubeconfig_file={shlex.quote(str(kubeconfig_file))}
                bootstrap_count_file="$PWD/bootstrap-count"
                TALOS_BOOTSTRAP_MAX_ATTEMPTS=3
                TALOS_BOOTSTRAP_RETRY_DELAY_SECONDS=0
                printf '0\\n' > "$bootstrap_count_file"
                : > "$LOG_FILE"

                log() {{
                  printf '%s\\n' "$*" >> "$LOG_FILE"
                }}

                wait_for_talos_api() {{
                  return 0
                }}

                upsert_secret_artifact() {{
                  printf 'UPSERT:%s/%s\\n' "$1" "$2" >> "$LOG_FILE"
                }}

                talosctl() {{
                  case "$1" in
                    bootstrap)
                      local bootstrap_calls=""
                      bootstrap_calls="$(cat "$bootstrap_count_file")"
                      bootstrap_calls=$((bootstrap_calls + 1))
                      printf '%s\\n' "$bootstrap_calls" > "$bootstrap_count_file"
                      printf 'BOOTSTRAP_CALL=%s\\n' "$bootstrap_calls" >> "$LOG_FILE"
                      if [[ "$bootstrap_calls" -lt 3 ]]; then
                        printf '%s\\n' 'rpc error: code = FailedPrecondition desc = bootstrap is not available yet' >&2
                        return 1
                      fi
                      return 0
                      ;;
                    kubeconfig)
                      printf 'kubeconfig\\n' > "$2"
                      return 0
                      ;;
                  esac

                  printf 'unexpected talosctl call: %s\\n' "$*" >&2
                  return 1
                }}

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^bootstrap_cluster\\(\\) \\{{/ {{ emit = 1 }}
                  /^sync_user_kubeconfig\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                bootstrap_cluster "192.168.2.237"
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
        assert log_text.count("BOOTSTRAP_CALL=") == 3
        assert "Talos bootstrap is not available yet on 192.168.2.237" in log_text
        assert "Writing kubeconfig" in log_text
        assert "UPSERT:kubeconfig/kubeconfig" in log_text


def test_rejects_control_plane_vip_assigned_by_dhcp():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        log_file = root / "vip.log"
        harness = root / "harness.sh"
        harness.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail

                APPLY_CLUSTER_SCRIPT={shlex.quote(str(APPLY_CLUSTER_SCRIPT))}
                LOG_FILE={shlex.quote(str(log_file))}
                VIP_IP=cluster-vip
                : > "$LOG_FILE"

                fail() {{
                  printf 'FAIL:%s\\n' "$*" >> "$LOG_FILE"
                  return 1
                }}

                HELPERS_FILE="$(mktemp)"
                awk '
                  /^ensure_vip_is_not_dhcp_assigned\\(\\) \\{{/ {{ emit = 1 }}
                  /^update_cluster_file\\(\\) \\{{/ {{ emit = 0 }}
                  emit {{ print }}
                ' "$APPLY_CLUSTER_SCRIPT" >"$HELPERS_FILE"
                source "$HELPERS_FILE"

                ensure_vip_is_not_dhcp_assigned '[["node-a"], ["cluster-vip"]]'
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

        assert proc.returncode != 0
        assert (
            "Control-plane VIP cluster-vip was assigned by DHCP to a VM. "
            "Reserve or exclude this address from DHCP, then retry from clean VMs."
            in log_file.read_text(encoding="utf-8")
        )


def test_generate_talos_configs_restores_existing_talos_secrets_before_generating():
    text = APPLY_CLUSTER_SCRIPT.read_text(encoding="utf-8")

    assert (
        'bootstrap_secret_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/secrets/cluster/${CLUSTER_ID}"'
        in text
    )
    assert "restore_secret_artifact()" in text
    assert 'restore_secret_artifact "talos-secrets" "secrets.yaml" "$talos_secrets_file"' in text
    assert text.index(
        'restore_secret_artifact "talos-secrets" "secrets.yaml" "$talos_secrets_file"'
    ) < text.index('if [[ -s "$talos_secrets_file" ]]; then')
