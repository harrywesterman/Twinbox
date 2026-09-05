import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "monitoring", ROOT / "scripts/manager/register-backup-vm-monitoring.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_monitoring_entrypoints_have_valid_shell_syntax():
    for name in [
        "configure-backup-storage.sh",
        "configure-seaweedfs-admin.sh",
        "register-backup-vm-monitoring.sh",
        "setup-backup-vm-monitoring-guest.sh",
        "install-prometheus.sh",
        "install-proxmox-backup-server.sh",
    ]:
        subprocess.run(["bash", "-n", str(ROOT / "scripts/manager" / name)], check=True)


def test_backup_dashboard_uses_runtime_metrics_for_both_roles():
    resource = MODULE.dashboard_resource()
    assert resource["metadata"]["labels"]["grafana_dashboard"] == "1"
    dashboard = json.loads(resource["data"]["twinbox-backup-vms.json"])
    assert dashboard["title"] == "Twinbox Backup VMs"
    for panel in dashboard["panels"]:
        assert 'vm_role=~"seaweedfs|pbs"' in panel["targets"][0]["expr"]
        assert panel["datasource"]["uid"] == "Prometheus"


def test_only_ready_managed_guest_profiles_are_registered(tmp_path):
    for folder in ["backup-storage", "pbs"]:
        (tmp_path / folder).mkdir()
    s3 = tmp_path / "backup-storage/metadata.json"
    pbs = tmp_path / "pbs/metadata.json"
    vm = {"status": "ready", "ip_address": "runtime-address", "ssh_private_key": "guest-key"}
    s3.write_text(json.dumps({"mode": "external-s3", "vm": vm}))
    pbs.write_text(json.dumps({**vm, "status": "provisioning"}))
    assert list(MODULE.ready_guests(tmp_path)) == []
    s3.write_text(json.dumps({"mode": "managed-seaweedfs", "vm": vm}))
    pbs.write_text(json.dumps(vm))
    assert [role for role, _ in MODULE.ready_guests(tmp_path)] == ["seaweedfs", "pbs"]


def test_metrics_match_existing_grafana_node_exporter_dashboard():
    for role in ["seaweedfs", "pbs"]:
        service, endpoint, monitor = MODULE.monitoring_resources(role, "discovered-address")
        assert "selector" not in service["spec"]
        assert endpoint["subsets"][0]["addresses"] == [{"ip": "discovered-address"}]
        assert service["metadata"]["labels"]["job"] == "node-exporter"
        assert monitor["spec"]["jobLabel"] == "job"
        assert (
            monitor["spec"]["selector"]["matchLabels"]["app"]
            == service["metadata"]["labels"]["app"]
        )
        assert "vm_role" in monitor["spec"]["targetLabels"]
        assert MODULE.monitoring_resources(role, "discovered-address") == [
            service,
            endpoint,
            monitor,
        ]
