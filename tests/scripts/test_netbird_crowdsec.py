"""CrowdSec configuration contracts for the Twinbox-managed NetBird bastion."""

import importlib.util
import json
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    path = ROOT / "scripts" / "manager" / name
    spec = importlib.util.spec_from_file_location(name.removesuffix(".py").replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CONFIGURE = load_script("configure-netbird-crowdsec.py")
RECONCILE = load_script("reconcile-netbird-crowdsec-services.py")


def make_install(tmp_path):
    (tmp_path / ".twinbox-bastion.json").write_text(
        json.dumps(
            {
                "managed_by": "twinbox",
                "component": "netbird-bastion",
                "netbird_domain": "netbird.example.test",
            }
        ),
        encoding="utf-8",
    )
    compose = {
        "services": {
            "traefik": {
                "image": "traefik:old",
                "networks": ["netbird"],
                "command": ["--api.dashboard=true"],
            },
            "dashboard": {
                "networks": ["netbird"],
                "labels": ["traefik.http.routers.netbird-dashboard.middlewares=netbird-no-store"],
            },
            "netbird-server": {"networks": ["netbird"], "labels": []},
            "proxy": {
                "networks": ["netbird"],
                "labels": [
                    "traefik.tcp.routers.proxy-passthrough.rule=HostSNI(`*`)",
                    "traefik.tcp.services.proxy-tls.loadbalancer.serverstransport=pp-v2@file",
                ],
            },
        },
        "networks": {"netbird": {}},
    }
    (tmp_path / "docker-compose.yml").write_text(yaml.safe_dump(compose), encoding="utf-8")
    (tmp_path / "proxy.env").write_text("NB_PROXY_DOMAIN=example.test\n", encoding="utf-8")
    (tmp_path / "traefik-dynamic.yaml").write_text("tcp: {}\n", encoding="utf-8")
    (tmp_path / "crowdsec").mkdir()
    (tmp_path / "crowdsec" / "acquis.yaml").write_text("source: file\n", encoding="utf-8")
    return tmp_path


def labels(service):
    return dict(item.split("=", 1) for item in service["labels"])


def test_configure_bastion_is_idempotent_and_keeps_separate_keys(tmp_path):
    install = make_install(tmp_path)
    CONFIGURE.configure(install)
    first_proxy = (install / "proxy.env").read_text(encoding="utf-8")
    first_dotenv = (install / ".env").read_text(encoding="utf-8")
    CONFIGURE.configure(install)
    assert (install / "proxy.env").read_text(encoding="utf-8") == first_proxy
    assert (install / ".env").read_text(encoding="utf-8") == first_dotenv
    backups = list((install / "backups").iterdir())
    assert len(backups) == 2
    assert all((backup / "traefik-dynamic.yaml").exists() for backup in backups)
    assert all((backup / "crowdsec" / "acquis.yaml").exists() for backup in backups)

    compose = yaml.safe_load((install / "docker-compose.yml").read_text(encoding="utf-8"))
    services = compose["services"]
    assert services["crowdsec"]["image"] == CONFIGURE.CROWDSEC_IMAGE
    assert services["crowdsec"]["environment"]["COLLECTIONS"] == CONFIGURE.COLLECTIONS
    assert services["traefik"]["image"] == CONFIGURE.TRAEFIK_IMAGE
    assert services["proxy"]["depends_on"]["crowdsec"]["condition"] == "service_healthy"
    assert services["traefik"]["depends_on"]["crowdsec"]["condition"] == "service_healthy"
    dash_labels = labels(services["dashboard"])
    api_labels = labels(services["netbird-server"])
    proxy_labels = labels(services["proxy"])
    assert "netbird-no-store" in dash_labels["traefik.http.routers.netbird-dashboard.middlewares"]
    assert CONFIGURE.MIDDLEWARE in dash_labels["traefik.http.routers.netbird-dashboard.middlewares"]
    assert (
        CONFIGURE.MIDDLEWARE in api_labels["traefik.http.routers.netbird-dashboard-api.middlewares"]
    )
    assert (
        "netbird-no-store" in api_labels["traefik.http.routers.netbird-dashboard-api.middlewares"]
    )
    assert "/api" in api_labels["traefik.http.routers.netbird-dashboard-api.rule"]
    assert "/oauth2" in api_labels["traefik.http.routers.netbird-dashboard-api.rule"]
    assert not any("crowdsec" in key for key in proxy_labels)
    assert "CROWDSEC_PROXY_BOUNCER_KEY=" in first_dotenv
    assert "CROWDSEC_DASHBOARD_BOUNCER_KEY=" in first_dotenv
    assert "NB_PROXY_CROWDSEC_API_KEY=" in first_proxy
    assert "listen_addr: :7422" in (install / "crowdsec" / "acquis.d" / "appsec.yaml").read_text(
        encoding="utf-8"
    )


def test_configure_rejects_unowned_install(tmp_path):
    install = make_install(tmp_path)
    (install / ".twinbox-bastion.json").unlink()
    with pytest.raises(ValueError, match="unowned"):
        CONFIGURE.configure(install)
    assert not (install / ".env").exists()


def test_configure_rejects_missing_proxy_protocol(tmp_path):
    install = make_install(tmp_path)
    compose_path = install / "docker-compose.yml"
    compose = yaml.safe_load(compose_path.read_text(encoding="utf-8"))
    compose["services"]["proxy"]["labels"] = []
    compose_path.write_text(yaml.safe_dump(compose), encoding="utf-8")
    with pytest.raises(ValueError, match="PROXY protocol"):
        CONFIGURE.configure(install)


def test_configure_rejects_reused_bouncer_key(tmp_path):
    install = make_install(tmp_path)
    (install / ".env").write_text("CROWDSEC_DASHBOARD_BOUNCER_KEY=same-key\n", encoding="utf-8")
    (install / "proxy.env").write_text("NB_PROXY_CROWDSEC_API_KEY=same-key\n", encoding="utf-8")
    with pytest.raises(ValueError, match="distinct"):
        CONFIGURE.configure(install)


def test_reconcile_preserves_existing_access_restrictions():
    service = {
        "id": "service-id",
        "name": "portal",
        "domain": "portal.example.test",
        "enabled": True,
        "targets": [{"target_id": "traefik-resource", "port": 8082}],
        "access_restrictions": {
            "allowed_cidrs": ["operator-supplied-range"],
            "crowdsec_mode": "off",
        },
        "auth": {"password_auth": {"enabled": True}},
    }
    payload = RECONCILE.build_update(service, "observe")
    assert payload["access_restrictions"] == {
        "allowed_cidrs": ["operator-supplied-range"],
        "crowdsec_mode": "observe",
    }
    assert payload["auth"] == service["auth"]
    assert "id" not in payload


def test_reconcile_zone_includes_special_services_but_excludes_other_zones():
    assert RECONCILE.belongs_to_zone({"domain": "netbird.example.test"}, "example.test")
    assert RECONCILE.belongs_to_zone({"domain": "backup-s3.example.test"}, "example.test")
    assert not RECONCILE.belongs_to_zone({"domain": "notexample.test"}, "example.test")


def test_new_netbird_service_defaults_to_enforce():
    text = (ROOT / "scripts" / "manager" / "ensure-netbird-service.sh").read_text(encoding="utf-8")
    assert 'CROWDSEC_MODE="enforce"' in text
    assert "access_restrictions: ($access_restrictions + {crowdsec_mode: $crowdsec_mode})" in text
    assert "EXISTING_ACCESS_RESTRICTIONS" in text
    bootstrap = (ROOT / "scripts" / "manager" / "netbird-bastion-bootstrap-template.sh").read_text(
        encoding="utf-8"
    )
    assert 'ENABLE_CROWDSEC="true"' in bootstrap
