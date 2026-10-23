#!/usr/bin/env python3
"""Configure CrowdSec for a Twinbox-owned NetBird bastion in place.

Run as root on the bastion. This changes configuration only; the caller starts
the affected Compose services after validating the result.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
from datetime import UTC, datetime
from pathlib import Path

import yaml

CROWDSEC_IMAGE = "crowdsecurity/crowdsec:v1.8.1"
TRAEFIK_IMAGE = "traefik:v3.7.14"
BOUNCER_PLUGIN_VERSION = "v1.7.1"
COLLECTIONS = (
    "crowdsecurity/linux crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
)
MIDDLEWARE = "netbird-dashboard-crowdsec@docker"


def read_env(path: Path) -> tuple[list[str], dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    values = {}
    for line in lines:
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("'\"")
    return lines, values


def put_env(lines: list[str], updates: dict[str, str]) -> str:
    seen = set()
    out = []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in updates and not line.lstrip().startswith("#"):
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")
    return "\n".join(out) + "\n"


def set_labels(service: dict, values: dict[str, str]) -> None:
    labels = service.setdefault("labels", [])
    if isinstance(labels, dict):
        labels.update(values)
        return
    if not isinstance(labels, list):
        raise ValueError("Compose labels must be a list or mapping")
    labels[:] = [
        item
        for item in labels
        if not isinstance(item, str) or "=" not in item or item.split("=", 1)[0] not in values
    ]
    labels.extend(f"{key}={value}" for key, value in values.items())


def append_middleware(service: dict, router: str) -> None:
    key = f"traefik.http.routers.{router}.middlewares"
    labels = service.setdefault("labels", [])
    current = (
        labels.get(key, "")
        if isinstance(labels, dict)
        else next(
            (
                item.split("=", 1)[1]
                for item in labels
                if isinstance(item, str) and item.startswith(key + "=")
            ),
            "",
        )
    )
    parts = [part.strip() for part in current.split(",") if part.strip()]
    if MIDDLEWARE not in parts:
        parts.append(MIDDLEWARE)
    set_labels(service, {key: ",".join(parts)})


def label_value(service: dict, key: str) -> str:
    labels = service.get("labels") or []
    if isinstance(labels, dict):
        return labels.get(key, "")
    return next((item.split("=", 1)[1] for item in labels if item.startswith(key + "=")), "")


def set_command(command: list[str], prefix: str, value: str) -> None:
    command[:] = [arg for arg in command if not arg.startswith(prefix)]
    command.append(value)


def depend_on(service: dict) -> None:
    deps = service.get("depends_on") or {}
    if isinstance(deps, list):
        deps = {name: {"condition": "service_started"} for name in deps}
    if not isinstance(deps, dict):
        raise ValueError("Compose depends_on must be a list or mapping")
    deps["crowdsec"] = {"condition": "service_healthy"}
    service["depends_on"] = deps


def compose_network(service: dict) -> str:
    networks = service.get("networks") or []
    if isinstance(networks, dict):
        networks = list(networks)
    if "netbird" not in networks:
        raise ValueError("Expected the existing NetBird Compose network")
    return "netbird"


def configure_compose(compose: dict, domain: str) -> dict:
    services = compose.get("services")
    if not isinstance(services, dict) or not all(
        name in services for name in ("traefik", "dashboard", "netbird-server", "proxy")
    ):
        raise ValueError("Expected NetBird combined-container proxy Compose stack")
    network = compose_network(services["proxy"])
    if network not in (services["traefik"].get("networks") or []):
        raise ValueError("Traefik and proxy must share a Docker network")
    if (
        label_value(
            services["proxy"],
            "traefik.tcp.services.proxy-tls.loadbalancer.serverstransport",
        )
        != "pp-v2@file"
    ):
        raise ValueError("NetBird proxy must receive the original client IP via PROXY protocol")

    crowdsec = services.setdefault("crowdsec", {})
    existing_env = crowdsec.get("environment") or {}
    if isinstance(existing_env, list):
        existing_env = dict(item.split("=", 1) for item in existing_env if "=" in item)
    if not isinstance(existing_env, dict):
        raise ValueError("CrowdSec environment must be a list or mapping")
    existing_env.update(
        {
            "COLLECTIONS": COLLECTIONS,
            "BOUNCER_KEY_netbird_proxy": "${CROWDSEC_PROXY_BOUNCER_KEY}",
            "BOUNCER_KEY_netbird_dashboard": "${CROWDSEC_DASHBOARD_BOUNCER_KEY}",
        }
    )
    crowdsec_networks = crowdsec.get("networks") or []
    if isinstance(crowdsec_networks, dict):
        crowdsec_networks = list(crowdsec_networks)
    if not isinstance(crowdsec_networks, list):
        raise ValueError("CrowdSec networks must be a list or mapping")
    if network not in crowdsec_networks:
        crowdsec_networks.append(network)
    crowdsec.update(
        image=CROWDSEC_IMAGE,
        container_name="netbird-crowdsec",
        restart="unless-stopped",
        networks=crowdsec_networks,
        environment=existing_env,
        healthcheck={
            "test": [
                "CMD-SHELL",
                "cscli lapi status >/dev/null 2>&1 && bash -c '</dev/tcp/localhost/7422'",
            ],
            "interval": "10s",
            "timeout": "5s",
            "retries": 15,
            "start_period": "30s",
        },
    )
    volumes = crowdsec.setdefault("volumes", [])
    for volume in ("./crowdsec:/etc/crowdsec", "crowdsec_db:/var/lib/crowdsec/data"):
        if volume not in volumes:
            volumes.append(volume)
    compose.setdefault("volumes", {}).setdefault("crowdsec_db", None)
    set_labels(crowdsec, {"traefik.enable": "false"})

    proxy = services["proxy"]
    depend_on(proxy)

    traefik = services["traefik"]
    traefik["image"] = TRAEFIK_IMAGE
    command = traefik.setdefault("command", [])
    if not isinstance(command, list):
        raise ValueError("Traefik command must be a list")
    command[:] = [arg for arg in command if "underscoreHeadersStrategy=" not in arg]
    for prefix, value in (
        (
            "--entrypoints.web.http.aliasHeadersStrategy=",
            "--entrypoints.web.http.aliasHeadersStrategy=delete",
        ),
        (
            "--entrypoints.websecure.http.aliasHeadersStrategy=",
            "--entrypoints.websecure.http.aliasHeadersStrategy=delete",
        ),
        (
            "--experimental.plugins.bouncer.modulename=",
            "--experimental.plugins.bouncer.modulename=github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin",
        ),
        (
            "--experimental.plugins.bouncer.version=",
            f"--experimental.plugins.bouncer.version={BOUNCER_PLUGIN_VERSION}",
        ),
    ):
        set_command(command, prefix, value)
    depend_on(traefik)

    dashboard = services["dashboard"]
    append_middleware(dashboard, "netbird-dashboard")
    set_labels(
        dashboard,
        {
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.enabled": "true",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecMode": "stream",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecLapiScheme": "http",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecLapiHost": "crowdsec:8080",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecLapiKey": "${CROWDSEC_DASHBOARD_BOUNCER_KEY}",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecAppsecEnabled": "true",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecAppsecHost": "crowdsec:7422",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecAppsecFailureBlock": "true",
            "traefik.http.middlewares.netbird-dashboard-crowdsec.plugin.bouncer.crowdsecAppsecUnreachableBlock": "true",
        },
    )

    server = services["netbird-server"]
    set_labels(
        server,
        {
            "traefik.http.routers.netbird-dashboard-api.rule": (
                f"Host(`{domain}`) && (PathPrefix(`/api`) || PathPrefix(`/oauth2`))"
            ),
            "traefik.http.routers.netbird-dashboard-api.entrypoints": "websecure",
            "traefik.http.routers.netbird-dashboard-api.tls": "true",
            "traefik.http.routers.netbird-dashboard-api.tls.certresolver": "letsencrypt",
            "traefik.http.routers.netbird-dashboard-api.service": "netbird-server",
            "traefik.http.routers.netbird-dashboard-api.priority": "110",
            "traefik.http.routers.netbird-dashboard-api.middlewares": "netbird-no-store",
        },
    )
    append_middleware(server, "netbird-dashboard-api")
    return compose


def write_private(path: Path, content: str) -> None:
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(content, encoding="utf-8")
    os.chmod(temp, 0o600)
    temp.replace(path)


def configure(install_dir: Path) -> None:
    marker = install_dir / ".twinbox-bastion.json"
    if not marker.is_file():
        raise ValueError("Refusing to change an unowned NetBird installation")
    identity = json.loads(marker.read_text(encoding="utf-8"))
    if identity.get("managed_by") != "twinbox" or identity.get("component") != "netbird-bastion":
        raise ValueError("Invalid Twinbox bastion ownership marker")
    domain = identity.get("netbird_domain")
    if not isinstance(domain, str) or not domain or "`" in domain:
        raise ValueError("Missing or invalid NetBird domain in ownership marker")

    compose_path = install_dir / "docker-compose.yml"
    proxy_env_path = install_dir / "proxy.env"
    dot_env_path = install_dir / ".env"
    if not compose_path.is_file() or not proxy_env_path.is_file():
        raise ValueError("NetBird Compose and proxy.env must already exist")
    compose = yaml.safe_load(compose_path.read_text(encoding="utf-8"))
    if not isinstance(compose, dict):
        raise ValueError("Invalid NetBird Compose file")
    proxy_lines, proxy_values = read_env(proxy_env_path)
    dot_lines, dot_values = read_env(dot_env_path)
    proxy_key = (
        dot_values.get("CROWDSEC_PROXY_BOUNCER_KEY")
        or proxy_values.get("NB_PROXY_CROWDSEC_API_KEY")
        or secrets.token_hex(32)
    )
    dashboard_key = dot_values.get("CROWDSEC_DASHBOARD_BOUNCER_KEY") or secrets.token_hex(32)
    if not proxy_key or not dashboard_key or proxy_key == dashboard_key:
        raise ValueError("CrowdSec bouncer keys must be distinct and non-empty")

    configure_compose(compose, domain)
    acquis_path = install_dir / "crowdsec" / "acquis.d" / "appsec.yaml"
    acquis_path.parent.mkdir(parents=True, exist_ok=True)
    backup_dir = (
        install_dir / "backups" / ("crowdsec-" + datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ"))
    )
    backup_dir.mkdir(parents=True, mode=0o700)
    for path in (
        compose_path,
        proxy_env_path,
        dot_env_path,
        install_dir / "traefik-dynamic.yaml",
    ):
        if path.exists():
            shutil.copy2(path, backup_dir / path.name)
    crowdsec_config = install_dir / "crowdsec"
    if crowdsec_config.is_dir():
        shutil.copytree(crowdsec_config, backup_dir / "crowdsec")

    write_private(
        dot_env_path,
        put_env(
            dot_lines,
            {
                "CROWDSEC_PROXY_BOUNCER_KEY": proxy_key,
                "CROWDSEC_DASHBOARD_BOUNCER_KEY": dashboard_key,
            },
        ),
    )
    write_private(
        proxy_env_path,
        put_env(
            proxy_lines,
            {
                "NB_PROXY_CROWDSEC_API_URL": "http://crowdsec:8080",
                "NB_PROXY_CROWDSEC_API_KEY": proxy_key,
            },
        ),
    )
    write_private(
        acquis_path,
        yaml.safe_dump(
            {
                "source": "appsec",
                "listen_addr": ":7422",
                "path": "/",
                "appsec_configs": ["crowdsecurity/appsec-default"],
                "labels": {"type": "appsec"},
            },
            sort_keys=False,
        ),
    )
    write_private(compose_path, yaml.safe_dump(compose, sort_keys=False))
    print(f"CrowdSec configuration updated; backup: {backup_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-dir", type=Path, default=Path("/opt/netbird"))
    args = parser.parse_args()
    configure(args.install_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
