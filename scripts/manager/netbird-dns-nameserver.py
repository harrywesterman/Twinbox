#!/usr/bin/env python3
"""Create or update a NetBird DNS nameserver group for AdGuard Home."""

import argparse
import json
import sys
import urllib.error
import urllib.request


def _request(method: str, url: str, token: str, data: dict | None = None) -> dict:
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        msg = f"HTTP {e.code} from {method} {url}"
        try:
            detail = json.loads(e.read().decode())
            msg += f": {detail}"
        except Exception:
            msg += f": {e.reason}"
        print(json.dumps({"error": msg}), file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Create or update a NetBird DNS nameserver group")
    parser.add_argument("--management-url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--description", default="")
    parser.add_argument("--group-id", action="append", required=True)
    parser.add_argument("--nameserver-ip", required=True)
    parser.add_argument("--nameserver-port", type=int, default=53)
    args = parser.parse_args()

    management_url = args.management_url.rstrip("/")

    # Check DNS settings for disabled management groups
    settings_url = f"{management_url}/api/dns/settings"
    settings = _request("GET", settings_url, args.token)
    disabled_groups = settings.get("disabled_management_groups", [])
    blocked_groups = [group_id for group_id in args.group_id if group_id in disabled_groups]
    if blocked_groups:
        print(
            json.dumps(
                {
                    "error": (
                        f"Groups {', '.join(blocked_groups)} are in disabled_management_groups. "
                        "Enable DNS management for these groups in NetBird settings first."
                    )
                }
            ),
            file=sys.stderr,
        )
        sys.exit(1)

    # Build nameserver group payload
    payload = {
        "name": args.name,
        "description": args.description,
        "nameservers": [
            {
                "ip": args.nameserver_ip,
                "ns_type": "udp",
                "port": args.nameserver_port,
            }
        ],
        "enabled": True,
        "groups": list(dict.fromkeys(args.group_id)),
        "primary": True,
        "domains": [],
        "search_domains_enabled": False,
    }

    # List existing nameserver groups
    list_url = f"{management_url}/api/dns/nameservers"
    existing_groups = _request("GET", list_url, args.token)
    matched = [g for g in existing_groups if g.get("name") == args.name]

    if matched:
        ns_id = matched[0]["id"]
        update_url = f"{management_url}/api/dns/nameservers/{ns_id}"
        result = _request("PUT", update_url, args.token, payload)
        action = "updated"
    else:
        result = _request("POST", list_url, args.token, payload)
        action = "created"

    output = {
        "action": action,
        "nameserver_group_id": result.get("id"),
        "nameserver_ip": args.nameserver_ip,
        "nameserver_port": args.nameserver_port,
    }
    print(json.dumps(output))


if __name__ == "__main__":
    main()
