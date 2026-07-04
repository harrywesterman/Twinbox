#!/usr/bin/env python3
"""Render the shared NetBird bastion bootstrap files for SSH-based installs."""

from __future__ import annotations

import argparse
import os
import shlex
from pathlib import Path


def shell_assign(key: str, value: str) -> str:
    return f"{key}={shlex.quote(value)}"


def write_private_file(path: Path, content: str, mode: int) -> None:
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--netbird-fqdn", required=True)
    parser.add_argument("--netbird-proxy-domain", required=True)
    parser.add_argument("--public-zone-name", required=True)
    parser.add_argument("--netbird-admin-email", required=True)
    parser.add_argument("--netbird-version", required=True)
    parser.add_argument("--dns-provider", required=True)
    parser.add_argument("--dns-api-token", required=True)
    parser.add_argument("--dns-api-secret", default="")
    parser.add_argument("--admin-token-expire-days", default="365")
    parser.add_argument("--opkssh-issuer-url", default="")
    parser.add_argument("--opkssh-client-id", default="")
    args = parser.parse_args()

    template = args.template.read_text(encoding="utf-8")
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    write_private_file(output_dir / "bootstrap-netbird.sh", template, 0o700)
    write_private_file(
        output_dir / "bootstrap.env",
        "\n".join(
            [
                shell_assign("NETBIRD_DOMAIN", args.netbird_fqdn),
                shell_assign("ADMIN_EMAIL", args.netbird_admin_email),
                shell_assign("NETBIRD_VERSION", args.netbird_version),
                shell_assign("PROXY_DOMAIN", args.netbird_proxy_domain),
                shell_assign("PUBLIC_ZONE_NAME", args.public_zone_name),
                shell_assign("DNS_PROVIDER", args.dns_provider),
                shell_assign("ADMIN_TOKEN_EXPIRE_DAYS", args.admin_token_expire_days),
                shell_assign("OPKSSH_ISSUER_URL", args.opkssh_issuer_url),
                shell_assign("OPKSSH_CLIENT_ID", args.opkssh_client_id),
            ]
        )
        + "\n",
        0o600,
    )
    write_private_file(
        output_dir / "dns-credentials",
        "\n".join(
            [
                shell_assign("DNS_API_TOKEN", args.dns_api_token),
                shell_assign("DNS_API_SECRET", args.dns_api_secret),
            ]
        )
        + "\n",
        0o600,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
