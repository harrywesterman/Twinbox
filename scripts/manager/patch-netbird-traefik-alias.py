#!/usr/bin/env python3
"""Add the NetBird public hostname as a Docker DNS alias for bastion Traefik."""

import argparse
import subprocess
from pathlib import Path

import yaml


def ensure_network_alias(service, network_name, alias):
    networks = service.get("networks")
    if networks is None:
        networks = {}
        service["networks"] = networks
    if isinstance(networks, list):
        next_networks = {}
        for item in networks:
            if isinstance(item, str):
                next_networks.setdefault(item, {})
            elif isinstance(item, dict):
                for key, value in item.items():
                    next_networks[key] = value or {}
        networks = next_networks
        service["networks"] = networks
    if isinstance(networks, dict):
        entry = networks.get(network_name)
        if entry is None:
            entry = {}
            networks[network_name] = entry
        elif isinstance(entry, list):
            entry = {"aliases": entry}
            networks[network_name] = entry
        elif not isinstance(entry, dict):
            entry = {}
            networks[network_name] = entry
        aliases = entry.setdefault("aliases", [])
        if not isinstance(aliases, list):
            aliases = [aliases]
            entry["aliases"] = aliases
        if alias not in aliases:
            aliases.append(alias)


def patch_compose_data(compose, alias, network_name="netbird"):
    if not isinstance(compose, dict):
        raise ValueError("compose document must be a mapping")

    services = compose.setdefault("services", {})
    traefik = services.get("traefik")
    if not isinstance(traefik, dict):
        raise ValueError("NetBird compose file has no traefik service")

    ensure_network_alias(traefik, network_name, alias)
    return compose


def patch_compose_file(compose_path, alias, network_name="netbird"):
    compose_path = Path(compose_path)
    if not compose_path.exists():
        raise FileNotFoundError(compose_path)

    compose = yaml.safe_load(compose_path.read_text()) or {}
    before = yaml.safe_dump(compose, default_flow_style=False, sort_keys=False)
    patch_compose_data(compose, alias, network_name)
    after = yaml.safe_dump(compose, default_flow_style=False, sort_keys=False)

    if after == before:
        return False

    compose_path.write_text(after)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compose-path", required=True)
    parser.add_argument("--alias", required=True)
    parser.add_argument("--network-name", default="netbird")
    parser.add_argument("--restart-traefik", action="store_true")
    args = parser.parse_args()

    changed = patch_compose_file(args.compose_path, args.alias, args.network_name)
    if changed and args.restart_traefik:
        subprocess.check_call(
            ["docker", "compose", "up", "-d", "traefik"],
            cwd=str(Path(args.compose_path).parent),
        )

    if changed:
        print(f"Added Docker alias {args.alias} to bastion Traefik.")
    else:
        print(f"Traefik already has Docker alias {args.alias}.")


if __name__ == "__main__":
    main()
