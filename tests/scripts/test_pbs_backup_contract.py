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
    assert "install-authentik-idp" in step
    assert "configure-netbird-ingress" in step
    assert "KUBECONFIG_FILE" in step
    assert "buckets.pbs" in runner
    assert "s3 endpoint create" in runner
    assert "s3 endpoint list --output-format json" in runner
    assert "s3 endpoint show" not in runner
    assert 'any(.[]; .id == "twinbox-s3")' in runner
    assert '--backend "type=s3,client=' in runner
    assert "DatastoreBackup" in runner
    assert "--auth-id pve@pbs!twinbox" in runner
    assert "--auth-id pve@pbs'" in runner
    assert "datastore update twinbox-s3 --backend" not in runner
    assert "Existing PBS datastore does not match the configured cache and S3 backend" in runner
    assert "keep-daily=14" in runner
    assert "keep-weekly=8" in runner
    assert "keep-monthly=12" in runner
    assert "exclude_vmids" in runner
    assert "MANAGEMENT_VM_ID" in runner
    assert "restore-read-test" in runner
    assert "qemu-server.conf.blob" in runner
    assert "user delete-token pve@pbs twinbox" in runner
    assert "generate-token pve@pbs twinbox --output-format" not in runner
    assert "sed '1s/^Result: //'" in runner
    assert "apt-get install -y proxmox-backup-server proxmox-backup-client" in runner
    assert "command -v proxmox-backup-client" in runner
    assert "pbs-enterprise.sources.disabled" in runner
    assert "packages: [qemu-guest-agent, curl, ca-certificates, gnupg, jq]" in runner
    assert runner.count("PBS_FINGERPRINT='${pbs_fingerprint}'") == 2
    assert "Refusing to resize the existing PBS cache disk implicitly" in runner
    assert 'select(.type == "node" and .name == $node)' in runner
    assert "pve_get '/cluster/resources?type=node'" in runner
    assert "select(.node == $node) | .status // empty" in runner
    assert "'.data.status // empty'" not in runner
    assert "disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1" in runner
    assert "test -b /dev/sdb" not in runner
    assert 'signatures="$(wipefs --no-act --noheadings --output TYPE "$disk")"' in runner
    assert '[[ -z "$signatures" ]]' in runner
    assert 'lsblk -nr -o TYPE "$disk"' in runner
    assert "UUID=%s %s ext4 defaults,nofail" in runner
    assert 'findmnt -nr -o UUID --target "$mountpoint"' in runner
    assert r"tmpdir=\$(mktemp -d)" in runner
    assert r"tmp=\"\$tmpdir/qemu-server.conf.blob\"" in runner
    assert 'TF_VAR_proxmox_endpoint="https://${node_ip}:${PROXMOX_PORT:-8006}"' in runner
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
    assert "overwrite_unmanaged = true" in module
    assert "overwrite  = true" in module
    assert "depends_on = [proxmox_virtual_environment_download_file.debian]" in module
    assert 'address = "${var.ip_address}/${var.prefix_length}"' in module
    assert "default" not in variables


def test_pbs_reverse_proxy_publication_contract():
    runner = (ROOT / "scripts/manager/install-proxmox-backup-server.sh").read_text()
    helper = (ROOT / "scripts/manager/configure-pbs-publication.sh").read_text()

    assert "configure-pbs-publication.sh" in runner
    assert "PBS_IP_ADDRESS=" in runner
    assert "PBS_SSH_PRIVATE_KEY=" in runner
    assert "PBS_PROFILE=" in runner
    assert "ensure-netbird-service.sh" in helper
    assert '--service-name "pbs"' in helper
    assert '--service-domain "pbs.${public_zone_name}"' in helper
    assert "gitops/apps/pbs.yaml" in helper
    assert "__ZONE_NAME__" in helper
    assert "__PBS_HOST_IP__" in helper
    assert "kubectl apply -f" in helper
    assert "openid create" in helper
    assert "openid update" in helper
    assert "--username-claim username" in helper
    assert "--autocreate 1" in helper
    assert "acl update / Admin" in helper
    assert 'matching_mode: "prefix"' in helper
    assert 'issuer_mode: "per_provider"' in helper
    assert "authorization_code" in helper
    assert "authentik_find_group_id" in helper
    assert "authentik_setup_forward" in helper
    assert "oidc_client_id" in helper
    assert "oidc_client_secret" in helper
