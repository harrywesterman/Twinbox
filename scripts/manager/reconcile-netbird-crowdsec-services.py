#!/usr/bin/env python3
"""Set CrowdSec mode on Twinbox NetBird services without changing other settings."""

from __future__ import annotations

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path

REQUEST_FIELDS = (
    "name",
    "domain",
    "enabled",
    "mode",
    "listen_port",
    "pass_host_header",
    "rewrite_redirects",
    "private",
    "access_groups",
    "auth",
    "targets",
    "access_restrictions",
)


def request_json(
    url: str, token: str, payload: dict | None = None, method: str = "GET"
) -> dict | list:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Token {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read()
    return json.loads(body) if body else {}


def collection(result: dict | list) -> list[dict]:
    if isinstance(result, list):
        return result
    if isinstance(result, dict):
        for key in ("services", "results", "items"):
            if isinstance(result.get(key), list):
                return result[key]
    raise ValueError("Unexpected NetBird services response")


def build_update(service: dict, mode: str) -> dict:
    payload = {key: service[key] for key in REQUEST_FIELDS if key in service}
    restrictions = payload.get("access_restrictions") or {}
    if not isinstance(restrictions, dict):
        raise ValueError("Invalid service access restrictions")
    payload["access_restrictions"] = {**restrictions, "crowdsec_mode": mode}
    if not all(payload.get(key) for key in ("name", "domain", "targets")):
        raise ValueError("Incomplete NetBird service cannot be reconciled")
    return payload


def belongs_to_zone(service: dict, zone: str) -> bool:
    domain = service.get("domain") or ""
    return domain == zone or domain.endswith("." + zone)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bastion-secret", required=True, type=Path)
    parser.add_argument("--network-secret", required=True, type=Path)
    parser.add_argument("--mode", choices=("observe", "enforce"), required=True)
    args = parser.parse_args()
    bastion = json.loads(args.bastion_secret.read_text(encoding="utf-8"))
    network = json.loads(args.network_secret.read_text(encoding="utf-8"))
    token = next(
        (
            bastion.get(key)
            for key in ("NETBIRD_ADMIN_TOKEN", "NETBIRD_API_TOKEN", "NETBIRD_SETUP_TOKEN")
            if bastion.get(key)
        ),
        None,
    )
    management_url = bastion.get("NETBIRD_URL")
    zone = bastion.get("NETBIRD_PROXY_DOMAIN")
    if not token or not management_url or not network.get("TRAEFIK_RESOURCE_ID") or not zone:
        raise ValueError("NetBird token, URL, proxy zone and Traefik resource are required")
    base = management_url.rstrip("/") + "/api/reverse-proxies/services"
    result = request_json(base + "?" + urllib.parse.urlencode({"page_size": 500}), token)
    services = collection(result)
    if isinstance(result, dict) and result.get("total", len(services)) > len(services):
        raise ValueError("NetBird service list was truncated; refusing partial reconciliation")
    changed = 0
    for service in services:
        if not belongs_to_zone(service, zone):
            continue
        service_id = service.get("id")
        if not service_id:
            raise ValueError("Twinbox service is missing its NetBird ID")
        payload = build_update(service, args.mode)
        if payload["access_restrictions"] == (service.get("access_restrictions") or {}):
            continue
        request_json(base + "/" + urllib.parse.quote(service_id, safe=""), token, payload, "PUT")
        changed += 1
    print(f"Reconciled CrowdSec {args.mode} mode on {changed} Twinbox NetBird services")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
