import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib import error, request

REPO_ROOT = Path(__file__).resolve().parents[2]


def _find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_health(base_url, timeout=10):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with request.urlopen(f"{base_url}/api/health", timeout=1) as resp:
                if resp.status == 200:
                    return
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("manager-api did not become healthy in time")


def _get_json(url):
    req = request.Request(url, method="GET")
    try:
        with request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, json.loads(body)


def _post_json(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, json.loads(body)


def _start_api(data_dir: Path, port: int):
    ping_mock = data_dir.parent / "mock-ping.sh"
    vm_mock = data_dir.parent / "mock-vms.sh"
    ping_mock.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    ping_mock.chmod(0o755)
    vm_mock.write_text(
        """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0},
  {"node": "pve-b", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0}
]
EOF
""",
        encoding="utf-8",
    )
    vm_mock.chmod(0o755)
    env = os.environ.copy()
    env["MANAGER_DATA_DIR"] = str(data_dir)
    env["MANAGER_API_PORT"] = str(port)
    env["WORKSPACE_ROOT"] = str(REPO_ROOT)
    env["MANAGER_API_PING_BIN"] = str(ping_mock)
    env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)
    return subprocess.Popen(
        ["node", "manager-api/src/server.js"],
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _global_step_state(data_dir: Path, step_id: str) -> Path:
    return data_dir / "step-state" / "global" / f"{step_id}.json"


def _cluster_step_state(data_dir: Path, cluster_id: str, step_id: str) -> Path:
    cluster_file = data_dir / "clusters" / f"{cluster_id}.json"
    if cluster_file.exists():
        cluster = json.loads(cluster_file.read_text())
        scope_id = (
            cluster.get("cluster_instance_id")
            or cluster.get("instance_id")
            or cluster.get("id")
            or cluster_id
        )
    else:
        scope_id = cluster_id

    return data_dir / "step-state" / "clusters" / scope_id / f"{step_id}.json"


def _write_cluster_file(
    data_dir: Path,
    cluster_id: str,
    *,
    slug: str | None = None,
    dns_domain: str = "example.com",
    selected_ingress_route: str | None = None,
    updated_at: str | None = None,
):
    cluster_file = data_dir / "clusters" / f"{cluster_id}.json"
    cluster_file.parent.mkdir(parents=True, exist_ok=True)
    cluster = {
        "id": cluster_id,
        "slug": slug or cluster_id,
        "dns_domain": dns_domain,
    }
    if selected_ingress_route is not None:
        cluster["selected_ingress_route"] = selected_ingress_route
    if updated_at is not None:
        cluster["updated_at"] = updated_at
    cluster_file.write_text(json.dumps(cluster), encoding="utf-8")


def _write_choose_ingress_state(data_dir: Path, cluster_id: str, route: str):
    state_file = data_dir / "step-state" / "clusters" / cluster_id / "choose-ingress-route.json"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(
        json.dumps(
            {
                "status": "configured",
                "inputs": {"ingress_route": route},
                "outputs": {"selected_ingress_route": route},
            }
        ),
        encoding="utf-8",
    )


def test_catalog_endpoint_returns_manifest_categories_and_steps():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200
            assert body["errors"] == []
            assert [category["id"] for category in body["categories"]] == [
                "talos-cluster",
            ]

            talos = body["categories"][0]
            talos_steps = {step["id"]: step for step in talos["steps"]}
            expected_talos_step_ids = {
                "provision-nodes",
                "install-argocd",
                "install-longhorn-storage",
                "install-secret-sync",
                "install-crowdsec",
                "install-traefik",
                "install-cloudnativepg",
                "choose-ingress-route",
                "install-authentik-idp",
                "create-users-and-groups",
                "install-headlamp",
                "install-browser-ssh",
                "install-grafana",
                "install-prometheus",
                "install-pgadmin4",
                "install-dashy-dashboard",
                "install-management-consoles",
                "install-ntfy",
                "install-velero-backup",
            }
            assert expected_talos_step_ids.issubset(talos_steps)
            assert talos_steps["provision-nodes"]["title"] == "Deploy Talos Cluster"
            assert talos_steps["install-argocd"]["title"] == "Install Argo CD"
            assert talos_steps["install-longhorn-storage"]["title"] == "Install Longhorn Storage"
            assert (
                talos_steps["install-secret-sync"]["title"]
                == "Install OpenBao and sync bootstrap secrets"
            )
            assert talos_steps["install-crowdsec"]["title"] == "Install CrowdSec"
            assert talos_steps["install-traefik"]["title"] == "Install Traefik"
            assert talos_steps["install-cloudnativepg"]["title"] == "Install CloudNativePG"

            assert talos_steps["choose-ingress-route"]["title"] == "Choose Ingress Route"
            assert talos_steps["install-authentik-idp"]["title"] == "Install Authentik"
            assert talos_steps["create-users-and-groups"]["title"] == "Create Users and Groups"
            assert talos_steps["install-headlamp"]["title"] == "Install Headlamp"
            assert talos_steps["install-browser-ssh"]["title"] == "Install Browser SSH"
            assert (
                talos_steps["install-browser-ssh"]["secrets"]["files"]["KUBECONFIG_FILE"]["item"]
                == "kubeconfig"
            )
            assert (
                talos_steps["install-browser-ssh"]["secrets"]["files"]["KUBECONFIG_FILE"][
                    "attachment"
                ]
                == "kubeconfig"
            )
            assert (
                talos_steps["install-browser-ssh"]["secrets"]["files"]["TWINBOX_TALOSCONFIG_FILE"][
                    "item"
                ]
                == "talosconfig"
            )
            assert (
                talos_steps["install-browser-ssh"]["secrets"]["files"]["TWINBOX_TALOSCONFIG_FILE"][
                    "attachment"
                ]
                == "talosconfig"
            )
            assert talos_steps["install-grafana"]["title"] == "Install Grafana"
            assert talos_steps["install-prometheus"]["title"] == "Install Prometheus"
            assert talos_steps["install-tempo"]["title"] == "Install Tempo"
            assert (
                talos_steps["install-tempo"]["secrets"]["files"]["KUBECONFIG_FILE"]["item"]
                == "kubeconfig"
            )
            assert (
                talos_steps["install-tempo"]["secrets"]["files"]["KUBECONFIG_FILE"]["attachment"]
                == "kubeconfig"
            )
            assert talos_steps["install-alloy"]["title"] == "Install Alloy"
            assert (
                talos_steps["install-alloy"]["secrets"]["files"]["KUBECONFIG_FILE"]["item"]
                == "kubeconfig"
            )
            assert (
                talos_steps["install-alloy"]["secrets"]["files"]["KUBECONFIG_FILE"]["attachment"]
                == "kubeconfig"
            )
            assert talos_steps["install-pgadmin4"]["title"] == "Install pgAdmin 4"
            assert talos_steps["install-dashy-dashboard"]["title"] == "Install Dashy dashboard"
            assert (
                talos_steps["install-management-consoles"]["title"] == "Install Management consoles"
            )
            assert talos_steps["install-ntfy"]["title"] == "Install Ntfy"
            assert "install-nextcloud" not in talos_steps
            assert "install-opencloud" not in talos_steps
            assert "install-immich" not in talos_steps
            assert "install-proxmox-backup-system" not in talos_steps
            assert "install-gitea" not in talos_steps
            assert "install-uptimekuma" not in talos_steps
            assert "install-adguard" not in talos_steps
            assert talos_steps["provision-nodes"]["journey_stage"] == "setup"
            assert talos_steps["provision-nodes"]["status"] == "ready"
            assert talos_steps["install-argocd"]["status"] == "ready"
            assert talos_steps["install-traefik"]["status"] == "ready"
            assert (
                talos_steps["install-traefik"]["secrets"]["files"]["KUBECONFIG_FILE"]["item"]
                == "kubeconfig"
            )
            assert (
                talos_steps["install-traefik"]["secrets"]["files"]["KUBECONFIG_FILE"]["attachment"]
                == "kubeconfig"
            )
            assert talos_steps["provision-nodes"]["icon"] == "🖥️"
            assert talos_steps["choose-ingress-route"]["type"] == "config"
            assert [
                input_def["id"] for input_def in talos_steps["choose-ingress-route"]["inputs"]
            ] == [
                "ingress_route",
            ]
            assert [
                option["value"]
                for option in talos_steps["choose-ingress-route"]["inputs"][0]["options"]
            ] == [
                "cloudflare-tunnel",
                "netbird",
            ]
            assert talos_steps["install-grafana"]["icon"] == "📈"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_apps_catalog_exposes_audiobookshelf_as_installable():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        _write_cluster_file(
            data_dir,
            "cluster-demo",
            slug="cluster-demo",
            dns_domain="example.com",
            selected_ingress_route="netbird",
            updated_at="2026-04-19T00:00:00Z",
        )
        for dependency in [
            "install-longhorn-storage",
            "install-cloudnativepg",
            "install-secret-sync",
            "install-authentik-idp",
            "create-users-and-groups",
            "choose-ingress-route",
        ]:
            _cluster_step_state(data_dir, "cluster-demo", dependency).parent.mkdir(
                parents=True, exist_ok=True
            )
            _cluster_step_state(data_dir, "cluster-demo", dependency).write_text(
                json.dumps(
                    {
                        "status": "succeeded",
                        "inputs": {},
                        "outputs": {},
                        "cluster_id": "cluster-demo",
                        "cluster_instance_id": "cluster-demo",
                        "error": None,
                        "updated_at": "2026-04-19T00:00:00Z",
                        "last_job_id": None,
                    }
                ),
                encoding="utf-8",
            )

        port = _find_free_port()
        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/apps/catalog?cluster_id=cluster-demo")
            assert status == 200
            assert body["errors"] == []
            bundle_ids = [bundle["id"] for bundle in body["bundles"]]
            assert sorted(bundle_ids) == [
                "lasuite",
                "mijn-bureau",
                "nextcloud",
                "opendesk",
                "twinbox-desktop",
            ]
            assert body["bundles"][0]["iconUrl"] == "/assets/step-icons/install-outline.svg"
            assert body["bundles"][1]["iconUrl"] == "/assets/step-icons/install-nextcloud.svg"
            assert body["bundles"][2]["iconUrl"] == "/assets/step-icons/install-nextcloud.svg"
            assert body["bundles"][2]["apps"] == ["install-mailu", "install-nextcloud"]
            assert body["bundles"][3]["iconUrl"] == "/assets/step-icons/install-opencloud.svg"
            assert body["bundles"][4]["iconUrl"] == "/assets/step-icons/install-outline.svg"
            apps = body["categories"][0]["steps"]
            audiobookshelf = next(step for step in apps if step["id"] == "install-audiobookshelf")
            vaultwarden = next(step for step in apps if step["id"] == "install-vaultwarden")
            assert audiobookshelf["placeholder"] is False
            assert audiobookshelf["installable"] is True
            assert audiobookshelf["app_state"] == "ready"
            assert (
                audiobookshelf["runner"]["script"]
                == "categories/apps/steps/install-audiobookshelf/run.sh"
            )
            assert vaultwarden["placeholder"] is False
            assert vaultwarden["installable"] is True
            assert vaultwarden["app_state"] == "ready"
            assert (
                vaultwarden["runner"]["script"]
                == "categories/apps/steps/install-vaultwarden/run.sh"
            )
            outline = next(step for step in apps if step["id"] == "install-outline")
            assert outline["placeholder"] is False
            assert outline["installable"] is True
            assert outline["app_state"] == "ready"
            assert outline["runner"]["script"] == "categories/apps/steps/install-outline/run.sh"
            nextcloud = next(step for step in apps if step["id"] == "install-nextcloud")
            assert nextcloud["placeholder"] is False
            assert nextcloud["installable"] is True
            assert nextcloud["app_state"] == "ready"
            assert nextcloud["runner"]["script"] == "categories/apps/steps/install-nextcloud/run.sh"
            opencloud = next(step for step in apps if step["id"] == "install-opencloud")
            assert opencloud["placeholder"] is False
            assert opencloud["installable"] is True
            assert opencloud["app_state"] == "ready"
            assert opencloud["runner"]["script"] == "categories/apps/steps/install-opencloud/run.sh"
            openwebui = next(step for step in apps if step["id"] == "install-openwebui")
            assert openwebui["placeholder"] is False
            assert openwebui["installable"] is True
            assert openwebui["app_state"] == "ready"
            assert openwebui["runner"]["script"] == "categories/apps/steps/install-openwebui/run.sh"
            penpot = next(step for step in apps if step["id"] == "install-penpot")
            assert penpot["placeholder"] is False
            assert penpot["installable"] is True
            assert penpot["app_state"] == "ready"
            assert penpot["runner"]["script"] == "categories/apps/steps/install-penpot/run.sh"
            mastodon = next(step for step in apps if step["id"] == "install-mastodon")
            assert mastodon["placeholder"] is False
            assert mastodon["installable"] is True
            assert mastodon["app_state"] == "ready"
            assert mastodon["runner"]["script"] == "categories/apps/steps/install-mastodon/run.sh"
            pixelfed = next(step for step in apps if step["id"] == "install-pixelfed")
            assert pixelfed["placeholder"] is False
            assert pixelfed["installable"] is True
            assert pixelfed["app_state"] == "ready"
            assert pixelfed["runner"]["script"] == "categories/apps/steps/install-pixelfed/run.sh"
            immich = next(step for step in apps if step["id"] == "install-immich")
            assert immich["placeholder"] is False
            assert immich["runner"]["script"] == "categories/apps/steps/install-immich/run.sh"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_endpoint_filters_ingress_routes_after_choice():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        route_state = _global_step_state(data_dir, "choose-ingress-route")
        route_state.parent.mkdir(parents=True, exist_ok=True)
        route_state.write_text(
            json.dumps(
                {
                    "status": "configured",
                    "inputs": {"ingress_route": "netbird"},
                    "outputs": {"selected_ingress_route": "netbird"},
                }
            ),
            encoding="utf-8",
        )
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200
            talos_step_ids = [step["id"] for step in body["categories"][0]["steps"]]
            assert "choose-ingress-route" in talos_step_ids
            assert "provision-netbird-bastion" in talos_step_ids
            assert "configure-netbird-ingress" in talos_step_ids
            assert "install-netbird-routing-peers" in talos_step_ids
            assert "configure-netbird-admin-access" in talos_step_ids
            assert "configure-cloudflare-tunnel" not in talos_step_ids
            assert "configure-metallb-ingress" not in talos_step_ids
            assert "configure-tailscale-ingress" not in talos_step_ids
            assert "configure-wiredoor-ingress" not in talos_step_ids
            assert "provision-wiredoor-bastion" not in talos_step_ids
            assert "install-wiredoor-gateway" not in talos_step_ids
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_endpoint_shows_cloudflare_only_for_prd_clusters():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        _write_cluster_file(
            data_dir,
            "prd",
            slug="prd",
            selected_ingress_route="cloudflare-tunnel",
            updated_at="2026-04-02T00:00:00Z",
        )
        _write_cluster_file(
            data_dir,
            "tst",
            slug="tst",
            selected_ingress_route="cloudflare-tunnel",
            updated_at="2026-04-03T00:00:00Z",
        )
        _write_choose_ingress_state(data_dir, "prd", "cloudflare-tunnel")
        _write_choose_ingress_state(data_dir, "tst", "cloudflare-tunnel")
        global_state = _global_step_state(data_dir, "choose-ingress-route")
        global_state.parent.mkdir(parents=True, exist_ok=True)
        global_state.write_text(
            json.dumps(
                {
                    "status": "configured",
                    "inputs": {"ingress_route": "cloudflare-tunnel"},
                    "outputs": {
                        "selected_ingress_route": "cloudflare-tunnel",
                        "cluster_id": "tst",
                    },
                }
            ),
            encoding="utf-8",
        )

        port = _find_free_port()
        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200
            talos = body["categories"][0]
            choose_step = next(
                step for step in talos["steps"] if step["id"] == "choose-ingress-route"
            )
            assert [option["value"] for option in choose_step["inputs"][0]["options"]] == [
                "netbird",
            ]
            assert "configure-cloudflare-tunnel" not in [step["id"] for step in talos["steps"]]

            status, body = _get_json(f"{base}/api/catalog?cluster_id=prd")
            assert status == 200
            talos = body["categories"][0]
            choose_step = next(
                step for step in talos["steps"] if step["id"] == "choose-ingress-route"
            )
            assert [option["value"] for option in choose_step["inputs"][0]["options"]] == [
                "cloudflare-tunnel",
                "netbird",
            ]
            assert "configure-cloudflare-tunnel" in [step["id"] for step in talos["steps"]]

            status, body = _get_json(f"{base}/api/catalog?cluster_id=tst")
            assert status == 200
            talos = body["categories"][0]
            choose_step = next(
                step for step in talos["steps"] if step["id"] == "choose-ingress-route"
            )
            assert [option["value"] for option in choose_step["inputs"][0]["options"]] == [
                "netbird",
            ]
            assert "configure-cloudflare-tunnel" not in [step["id"] for step in talos["steps"]]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_rejects_invalid_manifest_inputs():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/provision-nodes/execute",
                {"inputs": {"controlplane_count": 0}},
            )
            assert status == 400
            assert "controlplane_count" in body["error"]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_proxmox_cluster_resources_exposes_vm_storage_capabilities():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()
        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)
            status, body = _get_json(f"{base}/api/proxmox/cluster-resources")
            assert status == 200
            assert [storage["storage"] for storage in body["storages"]] == [
                "local-lvm",
                "local-lvm",
            ]
            assert all(storage["content"] == ["images"] for storage in body["storages"])
            assert all(storage["active"] and storage["enabled"] for storage in body["storages"])
            assert all(storage["avail"] == 1099511627776 for storage in body["storages"])
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_persists_state_and_enqueues_run_step_job():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/provision-nodes/execute",
                {
                    "inputs": {
                        "name": "demo",
                        "controlplane_count": 1,
                        "worker_count": 2,
                        "cpu_cores": 2,
                        "memory_mb": 4096,
                        "disk_gb": 20,
                        "bridge": "vmbr0",
                        "start_vmid": 200,
                        "vip_ip": "192.168.1.50",
                    },
                    "vm_size_map": {
                        "cp-1": {
                            "cpu": 2,
                            "memory_mb": 3072,
                            "disk_gb": 10,
                        },
                        "worker-1": {
                            "cpu": 2,
                            "memory_mb": 4096,
                            "disk_gb": 192,
                        },
                        "worker-2": {
                            "cpu": 2,
                            "memory_mb": 4096,
                            "disk_gb": 192,
                        },
                    },
                    "vm_ip_map": {
                        "cp-1": "192.168.1.61",
                        "worker-1": "192.168.1.62",
                        "worker-2": "192.168.1.63",
                    },
                },
            )
            assert status == 202
            assert body["job_type"] == "run_step"
            assert body["step_id"] == "provision-nodes"

            step_state = json.loads(
                _cluster_step_state(data_dir, body["cluster_id"], "provision-nodes").read_text()
            )
            assert body["cluster_id"] == step_state["cluster_id"]
            assert step_state["step_id"] == "provision-nodes"
            assert step_state["inputs"]["name"] == "demo"
            assert step_state["status"] == "pending"

            cluster_file = data_dir / "clusters" / f"{body['cluster_id']}.json"
            cluster = json.loads(cluster_file.read_text())
            assert cluster["worker_disk_gb"] == cluster["vm_size_map"]["worker-1"]["disk_gb"]
            assert cluster["vm_size_map"]["worker-1"]["disk_gb"] >= 10
            assert cluster["vm_size_map"]["worker-2"]["disk_gb"] >= 10
            assert cluster["vm_size_map"]["worker-1"]["cpu"] >= 1
            assert cluster["vm_size_map"]["worker-2"]["cpu"] >= 1
            assert cluster["vm_storage_map"] == {
                "cp-1": "local-lvm",
                "worker-1": "local-lvm",
                "worker-2": "local-lvm",
            }

            job = json.loads((data_dir / "jobs" / f"{body['job_id']}.json").read_text())
            assert job["type"] == "run_step"
            assert job["payload"]["step_id"] == "provision-nodes"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_rebuilds_provisioned_cluster_with_a_fresh_session():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0},
  {"node": "pve-b", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0}
]
EOF
""",
            encoding="utf-8",
        )
        vm_mock.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            cluster_dir = data_dir / "clusters"
            cluster_dir.mkdir(parents=True, exist_ok=True)
            old_instance_id = "11111111-1111-1111-1111-111111111111"
            cluster_id = "demo"
            (cluster_dir / f"{cluster_id}.json").write_text(
                json.dumps(
                    {
                        "id": cluster_id,
                        "cluster_instance_id": old_instance_id,
                        "status": "bootstrapped",
                    }
                ),
                encoding="utf-8",
            )
            old_state_path = (
                data_dir / "step-state" / "clusters" / old_instance_id / "provision-nodes.json"
            )
            old_state_path.parent.mkdir(parents=True, exist_ok=True)
            old_state_path.write_text(
                json.dumps(
                    {
                        "step_id": "provision-nodes",
                        "status": "succeeded",
                        "inputs": {"name": "demo"},
                        "outputs": {"cluster_id": cluster_id},
                        "cluster_id": cluster_id,
                        "cluster_instance_id": old_instance_id,
                        "error": None,
                        "updated_at": "2026-03-20T10:00:00Z",
                        "last_job_id": None,
                    }
                ),
                encoding="utf-8",
            )

            payload = {
                "cluster_id": cluster_id,
                "cluster_instance_id": old_instance_id,
                "inputs": {
                    "name": "demo",
                    "controlplane_count": 1,
                    "worker_count": 2,
                    "cpu_cores": 2,
                    "memory_mb": 4096,
                    "disk_gb": 20,
                    "bridge": "vmbr0",
                    "start_vmid": 200,
                    "vip_ip": "192.168.1.50",
                    "node_prefix_length": 24,
                    "gateway_ip": "192.168.1.1",
                    "dns_servers": "1.1.1.1,8.8.8.8",
                    "dns_domain": "lab.local",
                },
                "vm_ip_map": {
                    "cp-1": "192.168.1.61",
                    "worker-1": "192.168.1.62",
                    "worker-2": "192.168.1.63",
                },
                "vm_node_map": {
                    "cp-1": "pve-a",
                    "worker-1": "pve-b",
                    "worker-2": "pve-a",
                },
            }

            status, body = _post_json(f"{base}/api/steps/provision-nodes/execute", payload)
            assert status == 202
            assert body["cluster_id"] == cluster_id
            assert body["cluster_instance_id"] != old_instance_id

            cluster = json.loads((cluster_dir / f"{cluster_id}.json").read_text())
            assert cluster["cluster_instance_id"] == body["cluster_instance_id"]

            new_state = json.loads(
                _cluster_step_state(data_dir, cluster_id, "provision-nodes").read_text()
            )
            assert new_state["cluster_instance_id"] == body["cluster_instance_id"]
            assert old_state_path.exists()
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_accepts_manual_vm_ip_map_without_allocation_recheck():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0},
  {"node": "pve-b", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0}
]
EOF
""",
            encoding="utf-8",
        )
        vm_mock.chmod(0o755)

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["WORKSPACE_ROOT"] = str(REPO_ROOT)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/provision-nodes/execute",
                {
                    "inputs": {
                        "name": "demo",
                        "controlplane_count": 1,
                        "worker_count": 1,
                        "cpu_cores": 2,
                        "memory_mb": 4096,
                        "disk_gb": 20,
                        "bridge": "vmbr0",
                        "start_vmid": 200,
                        "vip_ip": "192.168.1.50",
                        "node_prefix_length": 24,
                        "gateway_ip": "192.168.1.1",
                        "dns_servers": "1.1.1.1,8.8.8.8",
                        "dns_domain": "lab.local",
                    },
                    "vm_ip_map": {
                        "cp-1": "192.168.1.61",
                        "worker-1": "192.168.1.62",
                    },
                    "vm_node_map": {
                        "cp-1": "pve-a",
                        "worker-1": "pve-b",
                    },
                },
            )

            assert status == 202
            assert body["step_id"] == "provision-nodes"

            cluster = json.loads((data_dir / "clusters" / f"{body['cluster_id']}.json").read_text())
            assert cluster["vm_ip_map"] == {
                "cp-1": "192.168.1.61",
                "worker-1": "192.168.1.62",
            }
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_step_retries_existing_provisioned_cluster_without_allocation_recheck():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        ping_mock = Path(td) / "mock-ping.sh"
        vm_mock = Path(td) / "mock-vms.sh"
        ping_mock.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        ping_mock.chmod(0o755)
        vm_mock.write_text(
            """#!/bin/sh
cat <<'EOF'
[
  {"node": "pve-a", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0},
  {"node": "pve-b", "status": "online", "maxcpu": 16, "maxmem": 68719476736, "mem": 0, "maxdisk": 1099511627776, "disk": 0}
]
EOF
""",
            encoding="utf-8",
        )
        vm_mock.chmod(0o755)
        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["MANAGER_API_PING_BIN"] = str(ping_mock)
        env["MANAGER_API_CLUSTER_RESOURCES_BIN"] = str(vm_mock)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_health(f"http://127.0.0.1:{port}")

            cluster_dir = data_dir / "clusters"
            cluster_dir.mkdir(parents=True, exist_ok=True)
            cluster_instance_id = "11111111-1111-1111-1111-111111111111"
            (cluster_dir / "demo.json").write_text(
                json.dumps(
                    {
                        "id": "demo",
                        "cluster_instance_id": cluster_instance_id,
                        "status": "failed",
                    }
                ),
                encoding="utf-8",
            )

            payload = {
                "cluster_id": "demo",
                "cluster_instance_id": cluster_instance_id,
                "inputs": {
                    "name": "demo",
                    "controlplane_count": 1,
                    "worker_count": 2,
                    "cpu_cores": 2,
                    "memory_mb": 4096,
                    "disk_gb": 20,
                    "bridge": "vmbr0",
                    "start_vmid": 200,
                    "vip_ip": "192.168.1.50",
                    "node_prefix_length": 24,
                    "gateway_ip": "192.168.1.1",
                    "dns_servers": "1.1.1.1,8.8.8.8",
                    "dns_domain": "lab.local",
                },
                "vm_ip_map": {
                    "cp-1": "192.168.1.61",
                    "worker-1": "192.168.1.62",
                    "worker-2": "192.168.1.63",
                },
                "vm_node_map": {
                    "cp-1": "pve-a",
                    "worker-1": "pve-b",
                    "worker-2": "pve-a",
                },
            }

            status, body = _post_json(
                f"http://127.0.0.1:{port}/api/steps/provision-nodes/execute", payload
            )
            assert status == 202
            assert body["step_id"] == "provision-nodes"
            assert body["cluster_id"] == "demo"

            job = json.loads((data_dir / "jobs" / f"{body['job_id']}.json").read_text())
            assert job["type"] == "run_step"
            assert job["cluster_id"] == "demo"
            assert job["payload"]["context"]["cluster"]["id"] == "demo"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_catalog_endpoint_isolates_invalid_manifest_entries():
    with tempfile.TemporaryDirectory() as td:
        temp_root = Path(td)
        data_dir = temp_root / "data"
        workspace_root = temp_root / "workspace"
        shutil.copytree(REPO_ROOT / "categories", workspace_root / "categories")

        broken_category_dir = workspace_root / "categories" / "broken-category"
        broken_category_dir.mkdir(parents=True)
        (broken_category_dir / "category.yaml").write_text(
            "id: broken-category\ntitle: Broken Category\norder: 99\n",
            encoding="utf-8",
        )

        port = _find_free_port()
        env = os.environ.copy()
        env["MANAGER_DATA_DIR"] = str(data_dir)
        env["MANAGER_API_PORT"] = str(port)
        env["WORKSPACE_ROOT"] = str(workspace_root)

        proc = subprocess.Popen(
            ["node", "manager-api/src/server.js"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog")
            assert status == 200
            assert [category["id"] for category in body["categories"]] == [
                "talos-cluster",
            ]
            assert any("broken-category" in error for error in body["errors"])
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        cluster_id = "compat-cluster"
        (data_dir / "clusters" / f"{cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": cluster_id,
                    "name": "compat-cluster",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:05:00Z",
                }
            ),
            encoding="utf-8",
        )
        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _get_json(f"{base}/api/catalog?cluster_id={cluster_id}")
            assert status == 200

            talos = body["categories"][0]
            talos_steps = {step["id"]: step for step in talos["steps"]}
            assert "provision-nodes" in talos_steps
            assert talos_steps["provision-nodes"]["status"] == "done"
            assert talos_steps["provision-nodes"]["state"]["cluster_id"] == cluster_id
            assert (
                talos_steps["provision-nodes"]["state"]["outputs"]["cluster_status"]
                == "bootstrapped"
            )
            assert "install-argocd" in talos_steps
            assert talos_steps["install-argocd"]["status"] == "ready"
            assert "install-longhorn-storage" in talos_steps
            assert talos_steps["install-longhorn-storage"]["status"] == "ready"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_follow_up_cluster_step_requires_explicit_cluster_context():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)
        (data_dir / "jobs").mkdir(parents=True, exist_ok=True)

        cluster_id = "cluster_followup"
        (data_dir / "clusters" / f"{cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": cluster_id,
                    "name": "twinbox-followup",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:10:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {
                                "scope": "cluster",
                                "item": "talos-secrets",
                                "cluster_id": cluster_id,
                            },
                            "talosconfig": {
                                "scope": "cluster",
                                "item": "talosconfig",
                                "cluster_id": cluster_id,
                            },
                            "kubeconfig": {
                                "scope": "cluster",
                                "item": "kubeconfig",
                                "cluster_id": cluster_id,
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "clusters" / cluster_id).mkdir(parents=True, exist_ok=True)
        _cluster_step_state(data_dir, cluster_id, "provision-nodes").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "followup"},
                    "outputs": {"cluster_id": cluster_id},
                    "cluster_id": cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        _cluster_step_state(data_dir, cluster_id, "install-argocd").write_text(
            json.dumps(
                {
                    "step_id": "install-argocd",
                    "status": "succeeded",
                    "inputs": {},
                    "outputs": {"cluster_id": cluster_id},
                    "cluster_id": cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:45Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        _cluster_step_state(data_dir, cluster_id, "install-longhorn-storage").write_text(
            json.dumps(
                {
                    "step_id": "install-longhorn-storage",
                    "status": "succeeded",
                    "inputs": {},
                    "outputs": {"cluster_id": cluster_id},
                    "cluster_id": cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:10:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/install-secret-sync/execute",
                {"inputs": {}},
            )
            assert status == 400
            assert body["error"] == "cluster_id is required for follow-up cluster steps"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_follow_up_cluster_step_uses_requested_cluster_context_and_secret_bundle():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)
        (data_dir / "jobs").mkdir(parents=True, exist_ok=True)

        selected_cluster_id = "cluster_followup"
        newer_cluster_id = "cluster_newer"
        (data_dir / "clusters" / f"{selected_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": selected_cluster_id,
                    "name": "twinbox-followup",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:10:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {
                                "scope": "cluster",
                                "item": "talos-secrets",
                                "cluster_id": selected_cluster_id,
                            },
                            "talosconfig": {
                                "scope": "cluster",
                                "item": "talosconfig",
                                "cluster_id": selected_cluster_id,
                            },
                            "kubeconfig": {
                                "scope": "cluster",
                                "item": "kubeconfig",
                                "cluster_id": selected_cluster_id,
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "clusters" / f"{newer_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": newer_cluster_id,
                    "name": "twinbox-newer",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T11:00:00Z",
                    "updated_at": "2026-03-20T11:05:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {
                                "scope": "cluster",
                                "item": "talos-secrets",
                                "cluster_id": newer_cluster_id,
                            },
                            "talosconfig": {
                                "scope": "cluster",
                                "item": "talosconfig",
                                "cluster_id": newer_cluster_id,
                            },
                            "kubeconfig": {
                                "scope": "cluster",
                                "item": "kubeconfig",
                                "cluster_id": newer_cluster_id,
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "clusters" / selected_cluster_id).mkdir(
            parents=True, exist_ok=True
        )
        _cluster_step_state(data_dir, selected_cluster_id, "provision-nodes").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "followup"},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        _cluster_step_state(data_dir, selected_cluster_id, "install-argocd").write_text(
            json.dumps(
                {
                    "step_id": "install-argocd",
                    "status": "succeeded",
                    "inputs": {},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:45Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        _cluster_step_state(data_dir, selected_cluster_id, "install-longhorn-storage").write_text(
            json.dumps(
                {
                    "step_id": "install-longhorn-storage",
                    "status": "succeeded",
                    "inputs": {},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:10:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        _cluster_step_state(data_dir, selected_cluster_id, "install-secret-sync").write_text(
            json.dumps(
                {
                    "step_id": "install-secret-sync",
                    "status": "succeeded",
                    "inputs": {},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:11:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/install-secret-sync/execute",
                {"cluster_id": selected_cluster_id, "inputs": {}},
            )
            assert status == 202

            job = json.loads((data_dir / "jobs" / f"{body['job_id']}.json").read_text())
            assert job["type"] == "run_step"
            assert job["cluster_id"] == selected_cluster_id
            assert job["payload"]["context"]["cluster"]["id"] == selected_cluster_id
            assert (
                job["payload"]["secret_bundle"]["files"]["KUBECONFIG_FILE"]["item"] == "kubeconfig"
            )
            assert (
                job["payload"]["secret_bundle"]["files"]["KUBECONFIG_FILE"]["attachment"]
                == "kubeconfig"
            )
        finally:
            proc.terminate()
            proc.wait(timeout=5)


def test_execute_argo_follow_up_cluster_step_uses_requested_cluster_context_and_secret_bundle():
    with tempfile.TemporaryDirectory() as td:
        data_dir = Path(td) / "data"
        port = _find_free_port()

        (data_dir / "clusters").mkdir(parents=True, exist_ok=True)
        (data_dir / "step-state").mkdir(parents=True, exist_ok=True)
        (data_dir / "jobs").mkdir(parents=True, exist_ok=True)

        selected_cluster_id = "cluster_followup"
        newer_cluster_id = "cluster_newer"
        (data_dir / "clusters" / f"{selected_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": selected_cluster_id,
                    "name": "twinbox-followup",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T10:00:00Z",
                    "updated_at": "2026-03-20T10:10:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {
                                "scope": "cluster",
                                "item": "talos-secrets",
                                "cluster_id": selected_cluster_id,
                            },
                            "talosconfig": {
                                "scope": "cluster",
                                "item": "talosconfig",
                                "cluster_id": selected_cluster_id,
                            },
                            "kubeconfig": {
                                "scope": "cluster",
                                "item": "kubeconfig",
                                "cluster_id": selected_cluster_id,
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "clusters" / f"{newer_cluster_id}.json").write_text(
            json.dumps(
                {
                    "id": newer_cluster_id,
                    "name": "twinbox-newer",
                    "status": "bootstrapped",
                    "created_at": "2026-03-20T11:00:00Z",
                    "updated_at": "2026-03-20T11:05:00Z",
                    "metadata": {
                        "secret_refs": {
                            "proxmox": {"scope": "global", "item": "proxmox"},
                            "talos_secrets": {
                                "scope": "cluster",
                                "item": "talos-secrets",
                                "cluster_id": newer_cluster_id,
                            },
                            "talosconfig": {
                                "scope": "cluster",
                                "item": "talosconfig",
                                "cluster_id": newer_cluster_id,
                            },
                            "kubeconfig": {
                                "scope": "cluster",
                                "item": "kubeconfig",
                                "cluster_id": newer_cluster_id,
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (data_dir / "step-state" / "clusters" / selected_cluster_id).mkdir(
            parents=True, exist_ok=True
        )
        (data_dir / "step-state" / "clusters" / newer_cluster_id).mkdir(parents=True, exist_ok=True)
        _cluster_step_state(data_dir, selected_cluster_id, "provision-nodes").write_text(
            json.dumps(
                {
                    "step_id": "provision-nodes",
                    "status": "succeeded",
                    "inputs": {"name": "followup"},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:09:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )
        _cluster_step_state(data_dir, selected_cluster_id, "install-argocd").write_text(
            json.dumps(
                {
                    "step_id": "install-argocd",
                    "status": "succeeded",
                    "inputs": {},
                    "outputs": {"cluster_id": selected_cluster_id},
                    "cluster_id": selected_cluster_id,
                    "error": None,
                    "updated_at": "2026-03-20T10:11:00Z",
                    "last_job_id": None,
                }
            ),
            encoding="utf-8",
        )

        proc = _start_api(data_dir, port)
        try:
            base = f"http://127.0.0.1:{port}"
            _wait_for_health(base)

            status, body = _post_json(
                f"{base}/api/steps/install-argocd/execute",
                {"cluster_id": selected_cluster_id, "inputs": {}},
            )
            assert status == 202

            job = json.loads((data_dir / "jobs" / f"{body['job_id']}.json").read_text())
            assert job["type"] == "run_step"
            assert job["cluster_id"] == selected_cluster_id
            assert job["payload"]["context"]["cluster"]["id"] == selected_cluster_id
            assert (
                job["payload"]["secret_bundle"]["files"]["KUBECONFIG_FILE"]["item"] == "kubeconfig"
            )
            assert (
                job["payload"]["secret_bundle"]["files"]["KUBECONFIG_FILE"]["attachment"]
                == "kubeconfig"
            )
        finally:
            proc.terminate()
            proc.wait(timeout=5)
