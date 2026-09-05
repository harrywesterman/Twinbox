from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_pbs_step_and_runner_contract():
    step = (
        ROOT / "categories/talos-cluster/steps/install-proxmox-backup-server/step.yaml"
    ).read_text()
    runner = (ROOT / "scripts/manager/install-proxmox-backup-server.sh").read_text()

    assert "configure-backup-storage" in step
    assert "min: 64" in step
    assert "default: 128" in step
    assert "pbs_node" in step and "pbs_cache_datastore" in step
    assert "pbs_cpu" in step and "pbs_memory_gb" in step and "pbs_system_disk_gb" in step
    assert "buckets.pbs" in runner
    assert "s3 endpoint create" in runner
    assert '--backend "type=s3,client=' in runner
    assert "DatastoreBackup" in runner
    assert "--auth-id pve@pbs!twinbox" in runner
    assert "keep-daily=14" in runner
    assert "keep-weekly=8" in runner
    assert "keep-monthly=12" in runner
    assert "exclude_vmids" in runner
    assert "MANAGEMENT_VM_ID" in runner
    assert "restore-read-test" in runner
    assert "qemu-server.conf.blob" in runner
    assert "user delete-token pve@pbs twinbox" in runner
    assert "Refusing to resize the existing PBS cache disk implicitly" in runner
    cloud_init = runner.split('cat >"$cloud_init" <<EOF', 1)[1].split("\nEOF", 1)[0]
    assert "pbs_admin_password" not in cloud_init


def test_pbs_vm_has_required_resources_and_no_fixed_network_defaults():
    module = (ROOT / "infra/opentofu/pbs-backup/main.tf").read_text()
    variables = (ROOT / "infra/opentofu/pbs-backup/variables.tf").read_text()

    assert "cores = var.cpu" in module
    assert "dedicated = var.memory_gb * 1024" in module
    assert "size         = var.system_disk_gb" in module
    assert "size         = var.cache_disk_gb" in module
    assert "datastore_id = var.cache_datastore_id" in module
    assert 'content_type = "import"' in module
    assert 'content_type = "snippets"' not in module
    assert "cloud_init_iso_path" in module
    assert 'address = "${var.ip_address}/${var.prefix_length}"' in module
    assert "default" not in variables
