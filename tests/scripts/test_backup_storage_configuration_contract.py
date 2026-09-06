import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_backup_storage_step_precedes_longhorn_and_exposes_both_modes():
    step = (ROOT / "categories/talos-cluster/steps/configure-backup-storage/step.yaml").read_text()
    journey = (ROOT / "manager-web/src/journey.js").read_text()

    assert "id: configure-backup-storage" in step
    assert "id: backup_storage_mode" in step
    assert "value: external-s3" in step
    assert "value: managed-seaweedfs" in step
    assert "id: s3_secret_access_key" in step
    assert "type: password" in step
    assert "sensitive: true" in step
    assert journey.index('"configure-backup-storage"') < journey.index('"install-longhorn-storage"')


def test_backup_storage_script_derives_cluster_scoped_bucket_names_and_tests_objects():
    script = (ROOT / "scripts/manager/configure-backup-storage.sh").read_text()

    for suffix in ["databases", "longhorn", "velero", "management", "pbs"]:
        assert f'twinbox_backup_bucket_name "$cluster_slug" {suffix}' in script
    assert "s3api create-bucket" in script
    assert "s3api put-object" in script
    assert "s3api head-object" in script
    assert "s3api get-object" in script
    assert "s3api delete-object" in script
    assert "secrets/cluster/${cluster_id}/backup-storage/metadata.json" in script


def test_bucket_names_are_deterministic_and_s3_length_safe():
    helper = ROOT / "scripts/manager/backup-bucket-name.sh"
    command = f"source {helper}; twinbox_backup_bucket_name {'x' * 80} databases"
    first = subprocess.check_output(["bash", "-c", command], text=True).strip()
    second = subprocess.check_output(["bash", "-c", command], text=True).strip()
    assert first == second
    assert len(first) <= 63
    assert first.endswith("-" + first.rsplit("-", 1)[1])


def test_worker_image_contains_s3_client_for_runtime_validation():
    dockerfile = (ROOT / "manager-worker/Dockerfile").read_text()
    assert "aws-cli" in dockerfile


def test_managed_seaweedfs_vm_is_idempotent_and_keeps_sensitive_state_in_secret_tree():
    script = (ROOT / "scripts/manager/provision-seaweedfs-backup-vm.sh").read_text()
    tofu = (ROOT / "infra/opentofu/seaweedfs-backup/main.tf").read_text()
    assert 'content_type = "snippets"' not in tofu
    assert "source_raw" not in tofu
    assert "user_data_file_id" not in tofu
    assert 'content_type = "import"' in tofu
    assert "overwrite_unmanaged = true" in tofu
    assert "var.cloud_init_iso_path" in tofu
    assert "overwrite  = true" in tofu
    assert "depends_on = [proxmox_virtual_environment_download_file.ubuntu]" in tofu
    assert "cdrom {" in tofu
    assert "boot_order" in tofu
    assert "-volid cidata" in script
    assert "defer: true" in script
    assert "sudo nginx -t; sudo systemctl enable nginx; sudo systemctl restart nginx" in script
    assert '"set -e; sudo install' in script
    assert 'if [[ "$vm_exists" == false ]]; then' in script
    assert 'select(.type == "node" and .name == $node)' in script
    assert 'TF_VAR_proxmox_endpoint="https://${node_ip}:${PROXMOX_PORT:-8006}"' in script

    assert "secrets/cluster/${TWINBOX_CLUSTER_ID}/backup-storage" in script
    assert ".vm.vm_id // empty" in script
    assert 'data_disk_gb" -ge 100' in script
    assert 'state_file="${secret_dir}/seaweedfs-vm.tfstate"' in script
    assert "Twinbox Backup CA" in script
    assert "Read,Write,List,Tagging,Admin" not in script
    assert "s3:CreateBucket" in script
    assert "s3.bucket.create -name=%s" in script
    assert 'profile_mode" == managed-seaweedfs' in script
    assert (
        "Refusing to change an existing backup storage mode implicitly"
        in (ROOT / "scripts/manager/configure-backup-storage.sh").read_text()
    )
    assert 'endpoint "https://${ip_address}"' in script
    assert 'resource "proxmox_virtual_environment_vm" "seaweedfs"' in tofu
    assert "cores = 2" in tofu
    assert "dedicated = 4096" in tofu
    assert "size         = 20" in tofu
    assert "ssh_private_key" in script
    cloud_init = script.split('cat >"$cloud_init" <<EOF', 1)[1].split("\nEOF", 1)[0]
    assert "secret_access_key" not in cloud_init
    assert "server_key" not in cloud_init


def test_managed_backup_vm_is_registered_in_existing_netbird_phase():
    network = (ROOT / "infra/opentofu/netbird-network/main.tf").read_text()
    runner = (ROOT / "categories/talos-cluster/steps/configure-netbird-ingress/run.sh").read_text()
    registration = (ROOT / "scripts/manager/register-backup-vms-netbird.sh").read_text()

    assert 'resource "netbird_setup_key" "backup_vms"' in network
    assert "register-backup-vms-netbird.sh" in runner
    assert "netbird up" in registration
