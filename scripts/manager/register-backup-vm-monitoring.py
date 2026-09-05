"""Register only provisioned guest VMs; never connect to Proxmox hosts."""

import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path


def monitoring_resources(role, address):
    name = f"twinbox-backup-{role}"
    labels = {"app": name, "job": "node-exporter", "vm_role": role}
    metadata = {"name": name, "namespace": "monitoring", "labels": labels}
    return [
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": metadata,
            "spec": {"ports": [{"name": "metrics", "port": 9100}]},
        },
        {
            "apiVersion": "v1",
            "kind": "Endpoints",
            "metadata": metadata,
            "subsets": [
                {"addresses": [{"ip": address}], "ports": [{"name": "metrics", "port": 9100}]}
            ],
        },
        {
            "apiVersion": "monitoring.coreos.com/v1",
            "kind": "ServiceMonitor",
            "metadata": metadata,
            "spec": {
                "selector": {"matchLabels": {"app": name}},
                "jobLabel": "job",
                "targetLabels": ["vm_role"],
                "endpoints": [{"port": "metrics", "interval": "60s"}],
            },
        },
    ]


def ready_guests(directory):
    for folder, role in [("backup-storage", "seaweedfs"), ("pbs", "pbs")]:
        file = directory / folder / "metadata.json"
        if not file.exists():
            continue
        profile = json.loads(file.read_text())
        if role == "seaweedfs" and profile.get("mode") != "managed-seaweedfs":
            continue
        vm = profile.get("vm", profile)
        if vm.get("status") == "ready" and vm.get("ip_address") and vm.get("ssh_private_key"):
            yield role, vm


def dashboard_resource():
    expressions = [
        ("VM reachable", 'up{vm_role=~"seaweedfs|pbs"}', "short"),
        (
            "CPU usage",
            '100 * (1 - avg by (instance, vm_role) (rate(node_cpu_seconds_total{vm_role=~"seaweedfs|pbs",mode="idle"}[5m])))',
            "percent",
        ),
        (
            "Memory usage",
            '100 * (1 - node_memory_MemAvailable_bytes{vm_role=~"seaweedfs|pbs"} / node_memory_MemTotal_bytes{vm_role=~"seaweedfs|pbs"})',
            "percent",
        ),
        (
            "Disk usage",
            '100 * (1 - node_filesystem_avail_bytes{vm_role=~"seaweedfs|pbs",fstype=~"ext4|xfs"} / node_filesystem_size_bytes{vm_role=~"seaweedfs|pbs",fstype=~"ext4|xfs"})',
            "percent",
        ),
    ]
    dashboard = {
        "uid": "twinbox-backup-vms",
        "title": "Twinbox Backup VMs",
        "schemaVersion": 39,
        "version": 1,
        "tags": ["Twinbox", "backups"],
        "time": {"from": "now-6h", "to": "now"},
        "refresh": "1m",
        "panels": [],
    }
    for index, (title, expression, unit) in enumerate(expressions):
        dashboard["panels"].append(
            {
                "id": index + 1,
                "title": title,
                "type": "timeseries",
                "datasource": {"type": "prometheus", "uid": "Prometheus"},
                "gridPos": {"x": (index % 2) * 12, "y": (index // 2) * 8, "w": 12, "h": 8},
                "fieldConfig": {"defaults": {"unit": unit}},
                "targets": [
                    {
                        "refId": "A",
                        "expr": expression,
                        "legendFormat": "{{vm_role}} {{instance}} {{mountpoint}}",
                    }
                ],
            }
        )
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "twinbox-backup-vms-dashboard",
            "namespace": "monitoring",
            "labels": {"grafana_dashboard": "1"},
        },
        "data": {"twinbox-backup-vms.json": json.dumps(dashboard)},
    }


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    root = Path(os.environ.get("TWINBOX_BOOTSTRAP_DIR", "/opt/twinbox/bootstrap"))
    guests = list(ready_guests(root / "secrets/cluster" / os.environ["TWINBOX_CLUSTER_ID"]))
    if not guests:
        print("No provisioned backup VMs to register")
        return
    secret = subprocess.run(
        ["kubectl", "-n", "beszel", "get", "secret", "beszel-agent-credentials", "-o", "json"],
        capture_output=True,
    )
    credentials = None
    if secret.returncode == 0:
        data = json.loads(secret.stdout)["data"]
        credentials = {
            key: base64.b64decode(data[key]).decode() for key in ["key", "token", "hub_url"]
        }
    monitor_ready = (
        subprocess.run(
            ["kubectl", "get", "crd", "servicemonitors.monitoring.coreos.com"], capture_output=True
        ).returncode
        == 0
    )
    for role, vm in guests:
        ssh = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "ConnectTimeout=10",
            "-i",
            vm["ssh_private_key"],
            "twinbox@" + vm["ip_address"],
        ]
        with tempfile.TemporaryDirectory() as directory:
            envfile = Path(directory) / "agent.env"
            if credentials:
                envfile.write_text(
                    "\n".join(
                        f"{key}={json.dumps(value)}"
                        for key, value in {
                            "KEY": credentials["key"],
                            "TOKEN": credentials["token"],
                            "HUB_URL": credentials["hub_url"],
                            "EXTRA_FILESYSTEMS": "sdb",
                        }.items()
                    )
                    + "\n"
                )
                envfile.chmod(0o600)
                run(ssh + ["sudo install -d -m 0700 /etc/twinbox-monitoring"])
                run(
                    ssh + ["sudo sh -c 'umask 077; cat > /etc/twinbox-monitoring/agent.env'"],
                    input=envfile.read_bytes(),
                )
            script = Path(__file__).with_name("setup-backup-vm-monitoring-guest.sh").read_bytes()
            version = os.environ["BESZEL_VERSION"]
            if not all(c in "0123456789." for c in version):
                raise ValueError("Invalid pinned Beszel version")
            run(ssh + [f"sudo bash -s -- {version} {'yes' if credentials else 'no'}"], input=script)
        if monitor_ready:
            run(
                ["kubectl", "apply", "-f", "-"],
                input=json.dumps(
                    {
                        "apiVersion": "v1",
                        "kind": "List",
                        "items": monitoring_resources(role, vm["ip_address"]),
                    }
                ).encode(),
            )
        print(
            f"Registered {role}: Beszel={'configured' if credentials else 'pending hub installation'}, Grafana={'node-exporter target configured' if monitor_ready else 'pending Prometheus installation'}"
        )

    if monitor_ready:
        run(["kubectl", "apply", "-f", "-"], input=json.dumps(dashboard_resource()).encode())


if __name__ == "__main__":
    main()
