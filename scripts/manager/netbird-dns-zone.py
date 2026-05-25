#!/usr/bin/env python3
"""Create or update a NetBird custom DNS zone and A records."""

import argparse
import json
import sys
import urllib.error
import urllib.request


def _request(method: str, url: str, token: str, data: dict | None = None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else None
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
    parser = argparse.ArgumentParser(description="Create or update a NetBird custom DNS zone")
    parser.add_argument("--management-url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--zone-name", required=True)
    parser.add_argument("--zone-domain", required=True)
    parser.add_argument("--group-id", action="append", required=True)
    parser.add_argument("--record", action="append", required=True, help="FQDN=IPv4 address")
    args = parser.parse_args()

    management_url = args.management_url.rstrip("/")
    zone_domain = args.zone_domain.rstrip(".")
    records = []
    for item in args.record:
        if "=" not in item:
            print(json.dumps({"error": f"Invalid record {item!r}; expected FQDN=IPv4"}), file=sys.stderr)
            sys.exit(1)
        name, content = item.split("=", 1)
        records.append({"name": name.rstrip("."), "type": "A", "content": content, "ttl": 300})

    zone_payload = {
        "name": args.zone_name,
        "domain": zone_domain,
        "enabled": True,
        "enable_search_domain": False,
        "distribution_groups": args.group_id,
    }

    zones_url = f"{management_url}/api/dns/zones"
    zones = _request("GET", zones_url, args.token)
    matched = [z for z in zones if z.get("domain") == zone_domain]
    if matched:
        zone_id = matched[0]["id"]
        zone = _request("PUT", f"{zones_url}/{zone_id}", args.token, zone_payload)
        action = "updated"
    else:
        zone = _request("POST", zones_url, args.token, zone_payload)
        zone_id = zone["id"]
        action = "created"

    records_url = f"{zones_url}/{zone_id}/records"
    existing_records = _request("GET", records_url, args.token)
    existing_by_name = {record.get("name"): record for record in existing_records}
    record_actions = []
    for payload in records:
        existing = existing_by_name.get(payload["name"])
        if existing:
            _request("PUT", f"{records_url}/{existing['id']}", args.token, payload)
            record_actions.append({"name": payload["name"], "action": "updated"})
        else:
            _request("POST", records_url, args.token, payload)
            record_actions.append({"name": payload["name"], "action": "created"})

    print(
        json.dumps(
            {
                "action": action,
                "zone_id": zone_id,
                "zone_domain": zone_domain,
                "records": record_actions,
            }
        )
    )


if __name__ == "__main__":
    main()
