#!/usr/bin/env python3
"""Ensure a Hetzner server IPv4 reverse DNS entry points at the desired host."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


API_BASE_URL = "https://api.hetzner.cloud/v1"
LIST_PAGE_SIZE = 50
ACTION_POLL_SECONDS = 2
ACTION_POLL_ATTEMPTS = 60
PTR_VERIFY_ATTEMPTS = 30
PTR_VERIFY_SECONDS = 2


class HetznerError(RuntimeError):
    """Raised when the Hetzner API returns an error or a lookup fails."""


def _api_error_message(exc: urllib.error.HTTPError, method: str, url: str) -> str:
    detail: str
    try:
        raw = exc.read().decode("utf-8")
        detail_json = json.loads(raw)
        detail = json.dumps(detail_json, sort_keys=True)
    except Exception:
        detail = exc.reason
    return f"HTTP {exc.code} from {method} {url}: {detail}"


def _request_json(
    method: str,
    path: str,
    token: str,
    payload: dict[str, object] | None = None,
):
    url = f"{API_BASE_URL}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raise HetznerError(_api_error_message(exc, method, url)) from exc

    if not raw:
        return {}
    return json.loads(raw)


def _server_name(server: dict[str, object]) -> str:
    value = server.get("name")
    return value if isinstance(value, str) else ""


def _server_id(server: dict[str, object]) -> int:
    value = server.get("id")
    if isinstance(value, int):
        return value
    raise HetznerError("Hetzner server response is missing a numeric id")


def _server_ipv4(server: dict[str, object]) -> str:
    public_net = server.get("public_net")
    if not isinstance(public_net, dict):
        return ""
    ipv4 = public_net.get("ipv4")
    if not isinstance(ipv4, dict):
        return ""
    ip = ipv4.get("ip")
    return ip if isinstance(ip, str) else ""


def _server_ipv4_ptr(server: dict[str, object]) -> str:
    public_net = server.get("public_net")
    if not isinstance(public_net, dict):
        return ""
    ipv4 = public_net.get("ipv4")
    if not isinstance(ipv4, dict):
        return ""
    ptr = ipv4.get("dns_ptr")
    return ptr if isinstance(ptr, str) else ""


def _get_server_by_name(token: str, server_name: str) -> dict[str, object] | None:
    if not server_name:
        return None

    query = urllib.parse.urlencode(
        {"name": server_name, "page": 1, "per_page": LIST_PAGE_SIZE}
    )
    response = _request_json("GET", f"/servers?{query}", token)
    servers = response.get("servers", [])
    if not isinstance(servers, list) or not servers:
        return None
    server = servers[0]
    return server if isinstance(server, dict) else None


def _iter_servers(token: str):
    page = 1
    while True:
        query = urllib.parse.urlencode({"page": page, "per_page": LIST_PAGE_SIZE})
        response = _request_json("GET", f"/servers?{query}", token)
        servers = response.get("servers", [])
        if isinstance(servers, list):
            for server in servers:
                if isinstance(server, dict):
                    yield server

        meta = response.get("meta", {})
        pagination = meta.get("pagination", {}) if isinstance(meta, dict) else {}
        last_page = pagination.get("last_page", page) if isinstance(pagination, dict) else page
        try:
            last_page_int = int(last_page)
        except Exception:
            last_page_int = page
        if page >= last_page_int:
            return
        page += 1


def _find_server_by_ipv4(token: str, ip: str) -> dict[str, object] | None:
    for server in _iter_servers(token):
        if _server_ipv4(server) == ip:
            return server
    return None


def _resolve_server(
    token: str,
    server_name: str,
    fallback_server_name: str,
    ip: str,
) -> dict[str, object]:
    mismatched_candidates: list[tuple[str, dict[str, object]]] = []
    for candidate_name in (server_name, fallback_server_name):
        if not candidate_name or any(existing_name == candidate_name for existing_name, _ in mismatched_candidates):
            continue
        server = _get_server_by_name(token, candidate_name)
        if server is None:
            continue
        if _server_ipv4(server) == ip:
            return server
        mismatched_candidates.append((candidate_name, server))

    server = _find_server_by_ipv4(token, ip)
    if server is not None:
        return server

    if mismatched_candidates:
        mismatch_details = [
            f"{candidate_name} -> {_server_ipv4(candidate) or 'missing IPv4'}"
            for candidate_name, candidate in mismatched_candidates
        ]
        raise HetznerError(
            "Hetzner server lookup matched by name but not by IPv4 "
            f"{ip}: {', '.join(mismatch_details)}"
        )

    raise HetznerError(
        f"Could not find a Hetzner server with IPv4 {ip} using "
        f"{server_name!r} or {fallback_server_name!r}"
    )


def _wait_for_action(server_id: int, action_id: int, token: str) -> dict[str, object]:
    for _ in range(ACTION_POLL_ATTEMPTS):
        response = _request_json("GET", f"/servers/{server_id}/actions/{action_id}", token)
        action = response.get("action", {})
        if not isinstance(action, dict):
            action = {}
        status = action.get("status")
        if status in {"success", "completed"}:
            return action
        if status in {"error", "failed"}:
            raise HetznerError(
                f"Hetzner PTR update action {action_id} for server {server_id} failed"
            )
        time.sleep(ACTION_POLL_SECONDS)

    raise HetznerError(
        f"Timed out waiting for Hetzner PTR update action {action_id} for server {server_id}"
    )


def _verify_dns_ptr(server_id: int, ip: str, ptr: str, token: str) -> dict[str, object]:
    for _ in range(PTR_VERIFY_ATTEMPTS):
        response = _request_json("GET", f"/servers/{server_id}", token)
        server = response.get("server", response)
        if isinstance(server, dict) and _server_ipv4(server) == ip and _server_ipv4_ptr(server) == ptr:
            return server
        time.sleep(PTR_VERIFY_SECONDS)

    raise HetznerError(
        f"Hetzner PTR for server {server_id} did not settle on {ptr} for IPv4 {ip}"
    )


def ensure_hetzner_rdns(
    *,
    token: str,
    server_name: str,
    fallback_server_name: str,
    ip: str,
    ptr: str,
) -> None:
    desired_ptr = ptr.rstrip(".")
    if not desired_ptr:
        raise HetznerError("PTR value is empty")

    server = _resolve_server(token, server_name, fallback_server_name, ip)
    server_id = _server_id(server)
    current_ptr = _server_ipv4_ptr(server)
    if current_ptr == desired_ptr:
        return

    response = _request_json(
        "POST",
        f"/servers/{server_id}/actions/change_dns_ptr",
        token,
        {"ip": ip, "dns_ptr": desired_ptr},
    )
    action = response.get("action", {})
    if not isinstance(action, dict):
        action = {}
    action_id = action.get("id")
    if not isinstance(action_id, int):
        raise HetznerError("Hetzner PTR update did not return an action id")

    _wait_for_action(server_id, action_id, token)
    _verify_dns_ptr(server_id, ip, desired_ptr, token)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ensure Hetzner reverse DNS is configured")
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--fallback-server-name", required=True)
    parser.add_argument("--ip", required=True)
    parser.add_argument("--ptr", required=True)
    args = parser.parse_args(argv)

    token = os.environ.get("HCLOUD_TOKEN", "").strip()
    if not token:
        raise HetznerError("HCLOUD_TOKEN environment variable is required")

    ensure_hetzner_rdns(
        token=token,
        server_name=args.server_name,
        fallback_server_name=args.fallback_server_name,
        ip=args.ip,
        ptr=args.ptr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HetznerError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
