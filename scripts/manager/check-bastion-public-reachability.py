#!/usr/bin/env python3
"""Check bastion public DNS records against an expected IPv4 target."""

from __future__ import annotations

import argparse
import ipaddress
import socket
import sys


def parse_record(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("records must use host=ipv4")
    host, expected = value.split("=", 1)
    host = host.strip()
    expected = expected.strip()
    if not host:
        raise argparse.ArgumentTypeError("record host is empty")
    try:
        ipaddress.IPv4Address(expected)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{expected!r} is not an IPv4 address") from exc
    return host, expected


def resolve_ipv4(host: str) -> set[str]:
    results = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    return {item[4][0] for item in results}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="append", type=parse_record, required=True)
    parser.add_argument("--warn-only", action="store_true")
    args = parser.parse_args()

    failed = False
    for host, expected in args.record:
        try:
            addresses = resolve_ipv4(host)
        except socket.gaierror as exc:
            print(f"{host}: DNS lookup failed: {exc}", file=sys.stderr)
            failed = True
            continue
        if expected not in addresses:
            found = ", ".join(sorted(addresses)) if addresses else "<none>"
            print(f"{host}: expected {expected}, found {found}", file=sys.stderr)
            failed = True
            continue
        print(f"{host}: resolves to {expected}")

    if failed and not args.warn_only:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
