#!/usr/bin/env python3
"""Runs on the bastion. Receives private deployment input over SSH stdin only."""

import fcntl
import hashlib
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

ROOT = Path("/opt/twinbox/gatus")
NETBIRD = Path("/opt/netbird/docker-compose.yml")
MARKER = Path("/opt/netbird/.twinbox-bastion.json")


def command(*args, timeout=120):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode:
        # Docker and provider errors may contain credentials. Never forward them.
        raise RuntimeError(f"Bastion command failed: {args[0]}")
    return result.stdout.strip()


def atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(content)
    temporary.replace(path)


def compose(*args):
    return command("docker", "compose", "--project-directory", str(ROOT), *args)


def inspect_service(service):
    container = command("docker", "compose", "-f", str(NETBIRD), "ps", "-q", service)
    if not container:
        raise RuntimeError(f"Missing running bastion service: {service}")
    return json.loads(command("docker", "inspect", container))[0]


def patch_passthrough(stack, hosts, previous_hosts=()):
    services = stack.get("services", {})
    proxy = services.get("proxy")
    if not proxy:
        raise RuntimeError("Missing NetBird proxy service")
    labels = proxy.get("labels", {})
    as_list = isinstance(labels, list)
    if as_list:
        labels = dict(label.split("=", 1) for label in labels if "=" in label)
    key = "traefik.tcp.routers.proxy-passthrough.rule"
    rule = labels.get(key, "")
    if "HostSNI" not in rule:
        raise RuntimeError("Missing managed TCP passthrough rule")
    for host in previous_hosts:
        rule = rule.replace(f" && !HostSNI(`{host}`)", "")
    for host in hosts:
        exclusion = f"!HostSNI(`{host}`)"
        if exclusion not in rule:
            rule += f" && {exclusion}"
    labels[key] = rule
    proxy["labels"] = [f"{key}={value}" for key, value in labels.items()] if as_list else labels
    return stack


def compose_config(image, network, hosts, entrypoint, resolver):
    labels = {
        "traefik.enable": "true",
        "traefik.docker.network": network,
        "traefik.http.services.twinbox-gatus.loadbalancer.server.port": "8080",
    }
    for index, host in enumerate(hosts):
        prefix = f"traefik.http.routers.twinbox-gatus-{index}"
        labels.update(
            {
                f"{prefix}.rule": f"Host(`{host}`)",
                f"{prefix}.entrypoints": entrypoint,
                f"{prefix}.tls": "true",
                f"{prefix}.tls.certresolver": resolver,
                f"{prefix}.tls.domains[0].main": host,
                f"{prefix}.service": "twinbox-gatus",
            }
        )
    return {
        "services": {
            "gatus": {
                "image": image,
                "restart": "unless-stopped",
                "mem_limit": "256m",
                "read_only": True,
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"],
                "volumes": ["./config:/config:ro", "./data:/data"],
                "environment": {
                    "GATUS_CONFIG_PATH": "/config/config.yaml",
                    "GATUS_LOG_LEVEL": "ERROR",
                },
                "networks": ["bastion"],
                "labels": labels,
                "logging": {"driver": "json-file", "options": {"max-size": "5m", "max-file": "3"}},
            }
        },
        "networks": {"bastion": {"external": True, "name": network}},
    }


def request_json(url, data, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {}, method="POST")
    with urllib.request.urlopen(request, timeout=15) as response:
        body = response.read(65536)
        return json.loads(body) if body else {}


def test_notification(provider, alerting):
    config = alerting.get(provider)
    if not config:
        raise RuntimeError("Selected notification channel is not enabled")
    message = "Twinbox: testmelding vanaf de bastion"
    try:
        if provider == "telegram":
            result = request_json(
                f"https://api.telegram.org/bot{config['token']}/sendMessage",
                urllib.parse.urlencode({"chat_id": config["id"], "text": message}).encode(),
            )
            if result.get("ok") is not True:
                raise RuntimeError("Rejected")
        elif provider == "pushover":
            result = request_json(
                "https://api.pushover.net/1/messages.json",
                urllib.parse.urlencode(
                    {
                        "token": config["application-token"],
                        "user": config["user-key"],
                        "message": message,
                    }
                ).encode(),
            )
            if result.get("status") != 1:
                raise RuntimeError("Rejected")
        elif provider == "ntfy":
            headers = {"Title": "Twinbox test"}
            if config.get("token"):
                headers["Authorization"] = f"Bearer {config['token']}"
            request_json(
                config["url"].rstrip("/") + "/" + urllib.parse.quote(config["topic"], safe=""),
                message.encode(),
                headers,
            )
        else:
            raise RuntimeError("Unknown channel")
    except Exception:
        raise RuntimeError(f"{provider}: test notification failed") from None
    return {"provider": provider, "sent": True}


def validate_candidate(image, config):
    # Start the exact image in an isolated network. No live alerts can escape.
    candidate = dict(config)
    candidate["storage"] = {"type": "memory"}
    with tempfile.TemporaryDirectory(prefix="gatus-validate-") as directory:
        file = Path(directory) / "config.yaml"
        atomic(file, yaml.safe_dump(candidate, sort_keys=False))
        name = f"twinbox-gatus-validate-{os.getpid()}"
        try:
            command(
                "docker",
                "run",
                "-d",
                "--name",
                name,
                "--network",
                "none",
                "--memory",
                "256m",
                "-e",
                "GATUS_LOG_LEVEL=INFO",
                "-v",
                f"{directory}:/config:ro",
                image,
            )
            for _ in range(20):
                state = json.loads(command("docker", "inspect", name))[0]["State"]
                output = subprocess.run(
                    ["docker", "logs", name], capture_output=True, text=True, check=False
                )
                logs = output.stdout + output.stderr
                # API initialization follows successful configuration validation.
                if state["Running"] and "Listening" in logs:
                    return
                if not state["Running"]:
                    break
                time.sleep(0.5)
            raise RuntimeError("Gatus candidate configuration failed validation")
        finally:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)


def wait_healthy():
    for _ in range(30):
        try:
            container = compose("ps", "-q", "gatus")
            info = json.loads(command("docker", "inspect", container))[0]
            address = next(
                entry["IPAddress"]
                for entry in info["NetworkSettings"]["Networks"].values()
                if entry.get("IPAddress")
            )
            with urllib.request.urlopen(f"http://{address}:8080/health", timeout=2) as response:
                if response.status == 200:
                    return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Gatus health check failed")


def wait_public(host):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"https://{host}/health", timeout=5) as response:
                if response.status == 200:
                    return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Public Gatus HTTPS check failed")


def coverage_warnings(config):
    warnings = []
    for endpoint in config.get("endpoints", []):
        if not endpoint["name"].startswith("Management VM · "):
            continue
        try:
            with urllib.request.urlopen(endpoint["url"], timeout=3) as response:
                if response.status != 200:
                    warnings.append(endpoint["group"])
        except Exception:
            warnings.append(endpoint["group"])
    return warnings


def apply(payload):
    stack = yaml.safe_load(NETBIRD.read_text())
    marker = json.loads(MARKER.read_text())
    if marker.get("managed_by") != "twinbox" or marker.get("component") != "netbird-bastion":
        raise RuntimeError("Refusing unmanaged bastion")
    traefik = inspect_service("traefik")
    networks = traefik["NetworkSettings"]["Networks"]
    args = traefik["Config"].get("Cmd") or []
    network = next(
        (arg.split("=", 1)[1] for arg in args if arg.startswith("--providers.docker.network=")),
        None,
    )
    if network not in networks:
        if len(networks) != 1:
            raise RuntimeError("Cannot discover bastion Docker network")
        network = next(iter(networks))
    labels = {}
    for service in stack.get("services", {}).values():
        service_labels = service.get("labels", {})
        if isinstance(service_labels, list):
            service_labels = dict(label.split("=", 1) for label in service_labels if "=" in label)
        labels.update(service_labels)
    entrypoint = next(
        (
            value
            for key, value in labels.items()
            if key.endswith(".entrypoints") and "dashboard" in key
        ),
        None,
    )
    resolver = next(
        (value for key, value in labels.items() if key.endswith(".tls.certresolver")), None
    )
    if not entrypoint or not resolver:
        raise RuntimeError("Cannot discover bastion HTTPS entrypoint and certificate resolver")
    hosts = sorted(set(payload["hosts"]))
    if not hosts or any(not re.fullmatch(r"status\.[a-zA-Z0-9.-]+", host) for host in hosts):
        raise RuntimeError("Invalid status hostname")
    config = payload["config"]
    if payload.get("test_provider"):
        saved = payload["test_alerting"]
        return test_notification(payload["test_provider"], saved)
    expected_address = payload.get("public_address")
    if expected_address:
        for host in hosts:
            addresses = {entry[4][0] for entry in socket.getaddrinfo(host, 443)}
            if expected_address not in addresses:
                raise RuntimeError("Status DNS does not resolve to the discovered bastion address")
    digest = hashlib.sha256(
        json.dumps(
            {"config": config, "image": payload["image"], "hosts": hosts}, sort_keys=True
        ).encode()
    ).hexdigest()
    digest_file = ROOT / "digest"
    if digest_file.exists() and digest_file.read_text() == digest:
        wait_healthy()
        return {"changed": False, "coverage_warnings": coverage_warnings(config)}
    command("docker", "pull", payload["image"], timeout=300)
    validate_candidate(payload["image"], config)
    backup = ROOT / "backups" / time.strftime("%Y%m%d-%H%M%S")
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(backup, 0o700)
    files = [
        NETBIRD,
        ROOT / "compose.yaml",
        ROOT / "config/config.yaml",
        ROOT / "notifications.json",
        ROOT / "hosts.json",
        digest_file,
    ]
    originals = {str(file): file.read_bytes() if file.exists() else None for file in files}
    previous_hosts = (
        json.loads((ROOT / "hosts.json").read_text()) if (ROOT / "hosts.json").exists() else []
    )
    for index, file in enumerate(files):
        if file.exists():
            target = backup / f"{index}-{file.name}"
            shutil.copyfile(file, target)
            os.chmod(target, 0o600)
    database = ROOT / "data/gatus.db"
    if database.exists():
        with (
            sqlite3.connect(database) as source,
            sqlite3.connect(backup / "gatus.db") as destination,
        ):
            source.backup(destination)
    try:
        (ROOT / "data").mkdir(mode=0o700, exist_ok=True)
        atomic(ROOT / "config/config.yaml", yaml.safe_dump(config, sort_keys=False))
        atomic(ROOT / "notifications.json", json.dumps(config.get("alerting", {})))
        atomic(ROOT / "hosts.json", json.dumps(hosts))
        atomic(
            ROOT / "compose.yaml",
            yaml.safe_dump(
                compose_config(payload["image"], network, hosts, entrypoint, resolver),
                sort_keys=False,
            ),
        )
        compose("config", "--quiet")
        atomic(
            NETBIRD,
            yaml.safe_dump(patch_passthrough(stack, hosts, previous_hosts), sort_keys=False),
        )
        command("docker", "compose", "-f", str(NETBIRD), "config", "--quiet")
        compose("up", "-d", "gatus")
        wait_healthy()
        command("docker", "compose", "-f", str(NETBIRD), "up", "-d", "proxy")
        # New mounts/config changes are activated deterministically; history stays on disk.
        compose("restart", "gatus")
        wait_healthy()
        for host in hosts:
            wait_public(host)
        atomic(digest_file, digest)
    except Exception:
        subprocess.run(
            ["docker", "compose", "--project-directory", str(ROOT), "stop", "gatus"],
            capture_output=True,
            check=False,
        )
        if originals[str(ROOT / "compose.yaml")] is None:
            subprocess.run(
                ["docker", "compose", "--project-directory", str(ROOT), "down"],
                capture_output=True,
                check=False,
            )
        if (backup / "gatus.db").exists():
            shutil.copyfile(backup / "gatus.db", database)
            for suffix in ("-wal", "-shm"):
                Path(str(database) + suffix).unlink(missing_ok=True)
        for filename, original in originals.items():
            file = Path(filename)
            if original is None:
                file.unlink(missing_ok=True)
            else:
                atomic(file, original.decode())
        subprocess.run(
            ["docker", "compose", "-f", str(NETBIRD), "up", "-d", "proxy"],
            capture_output=True,
            check=False,
        )
        if (ROOT / "compose.yaml").exists():
            compose("up", "-d", "--force-recreate", "gatus")
        raise RuntimeError("Gatus activation failed; previous configuration restored") from None
    return {"changed": True, "coverage_warnings": coverage_warnings(config)}


def main():
    payload = json.load(sys.stdin)
    ROOT.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(ROOT, 0o700)
    with (ROOT / ".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = apply(payload)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(
            "Gatus bastion operation failed; previous configuration retained where possible",
            file=sys.stderr,
        )
        sys.exit(1)
