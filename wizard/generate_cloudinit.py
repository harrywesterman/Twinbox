#!/usr/bin/env python3
"""
Cloud-init configuration generator for Twinbox.

This script generates cloud-init configuration files (ISO or snippet) with proper YAML formatting.
It handles all the multi-line content with correct indentation.
"""

import argparse
import os
import secrets
import string
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def generate_password(length: int = 16) -> str:
    """Generate a secure random password."""
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))


def get_env_or_generate(var_name: str, generator, default: bool = False) -> str:
    """Get environment variable or generate a value."""
    value = os.getenv(var_name)
    if not value:
        if default:
            return generator()
        raise ValueError(f"Missing required environment variable: {var_name}")
    return value


def generate_user_data(
    cluster_name: str,
    api_url: str,
    api_token_secret: str,
    ssh_public_key: Optional[str] = None,
    db_pass: Optional[str] = None,
    sec_key: Optional[str] = None,
    twinbox_pw: Optional[str] = None,
) -> dict:
    """Generate the cloud-config user-data dictionary."""

    # Generate passwords if not provided
    db_pass = db_pass or generate_password(32)
    sec_key = sec_key or generate_password(32)
    twinbox_pw = twinbox_pw or generate_password(12)

    # Import docker-compose.yml content
    docker_compose_path = Path(__file__).parent.parent / "manager" / "web" / "docker-compose.yml"
    docker_compose_content = ""
    if docker_compose_path.exists():
        docker_compose_content = docker_compose_path.read_text()
    else:
        # Fallback: generate inline (this shouldn't happen in normal operation)
        docker_compose_content = """version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: twinbox-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: twinbox
      POSTGRES_PASSWORD: twinbox_password
      POSTGRES_DB: twinbox
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - twinbox-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U twinbox"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  redis:
    image: redis:7-alpine
    container_name: twinbox-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - twinbox-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  web:
    build:
      context: .
      dockerfile: manager/web/Dockerfile
    container_name: twinbox-web
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      - DATABASE_URL=postgresql+psycopg2://twinbox:twinbox_password@postgres:5432/twinbox
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=dev-secret-change-in-production
    volumes:
      - ./manager/web:/app
    networks:
      - twinbox-network
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  worker:
    build:
      context: .
      dockerfile: manager/worker/Dockerfile
    container_name: twinbox-worker
    restart: unless-stopped
    environment:
      - DATABASE_URL=postgresql+psycopg2://twinbox:twinbox_password@postgres:5432/twinbox
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=dev-secret-change-in-production
    volumes:
      - ./manager/worker:/app
    networks:
      - twinbox-network
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "redis-cli", "-u", "redis://redis:6379/0", "LRANGE", "rq:worker:twobox-worker:queues", "0", "0"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  postgres_data:
  redis_data:

networks:
  twinbox-network:
    driver: bridge
"""

    # Systemd service file content
    systemd_service = """[Unit]
Description=Twinbox Management Console
Requires=docker.service
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker-compose -f /opt/twinbox/docker-compose.yml up -d
ExecStop=/usr/bin/docker-compose -f /opt/twinbox/docker-compose.yml down
User=twinbox
Group=twinbox
WorkingDirectory=/opt/twinbox
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"""

    # MOTD content
    motd = """==========================================
 Twinbox Management VM
==========================================

Web UI: http://<this-vm-ip>:8080
SSH: twinbox@<this-ip>

Twinbox repository: /opt/twinbox
Docker Compose: /opt/twinbox/docker-compose.yml

Status: systemctl status twinbox
Logs: journalctl -u twinbox -f

=========================================="""

    # Final message
    final_message = """==========================================
 Twinbox Setup Complete!
===========================================

Management VM is ready. The Twinbox web
interface should be accessible shortly.

SSH to this VM: ssh twinbox@<this-ip>
Password: {twinbox_pw}
View status: systemctl status twinbox
View logs: journalctl -u twinbox -f

===========================================""".format(twinbox_pw=twinbox_pw)

    # Build runcmd list
    runcmd = [
        ["groupadd", "twinbox"],
        ["useradd", "-g", "twinbox", "-m", "-s", "/bin/bash", "twinbox"],
        f"echo 'twinbox:{twinbox_pw}' | chpasswd",
        ["usermod", "-aG", "docker", "twinbox"],
        ["mkdir", "-p", "/opt/twinbox"],
        ["chown", "-R", "twinbox:twinbox", "/opt/twinbox"],
    ]

    # Add SSH key setup if provided
    if ssh_public_key:
        runcmd.extend([
            ["mkdir", "-p", "/home/twinbox/.ssh"],
            ["sh", "-c", f"echo '{ssh_public_key}' > /home/twinbox/.ssh/authorized_keys"],
            ["chmod", "600", "/home/twinbox/.ssh/authorized_keys"],
            ["chown", "-R", "twinbox:twinbox", "/home/twinbox/.ssh"],
        ])

    runcmd.extend([
        ["systemctl", "enable", "qemu-guest-agent"],
        ["systemctl", "start", "qemu-guest-agent"],
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", "twinbox.service"],
        ["systemctl", "start", "twinbox.service"],
        ["systemctl", "enable", "docker"],
        ["systemctl", "start", "docker"],
        ["systemctl", "restart", "ssh"],
    ])

    # Build write_files list
    write_files = [
        {
            "path": "/opt/twinbox/config/proxmox-creds.yaml",
            "permissions": "0600",
            "owner": "root:root",
            "content": f"""api_url: {api_url}
user: "twinbox@pve"
token: {api_token_secret}
verify_ssl: false""",
        },
        {
            "path": "/opt/twinbox/config/cluster-name",
            "permissions": "0644",
            "owner": "root:root",
            "content": f"CLUSTER_NAME={cluster_name}",
        },
        {
            "path": "/opt/twinbox/.env",
            "permissions": "0600",
            "owner": "root:root",
            "content": f"""DATABASE_URL=postgresql://twinbox:{db_pass}@localhost:5432/twinbox
REDIS_URL=redis://localhost:6379/0
SECRET_KEY={sec_key}
PROXMOX_CREDENTIALS_PATH=/opt/twinbox/config/proxmox-creds.yaml
CLUSTER_NAME={cluster_name}""",
        },
        {
            "path": "/opt/twinbox/docker-compose.yml",
            "permissions": "0644",
            "owner": "root:root",
            "content": docker_compose_content,
        },
        {
            "path": "/etc/systemd/system/twinbox.service",
            "permissions": "0644",
            "owner": "root:root",
            "content": systemd_service,
        },
        {
            "path": "/etc/motd",
            "permissions": "0644",
            "owner": "root:root",
            "content": motd,
        },
        {
            "path": "/etc/ssh/sshd_config.d/99-twinbox.conf",
            "permissions": "0644",
            "owner": "root:root",
            "content": "PasswordAuthentication yes",
        },
    ]

    # Build cloud-config dictionary
    user_data_dict = {
        "growpart": {
            "mode": "auto",
            "devices": ["/"],
            "ignore_growroot_disabled": True,
        },
        "package_update": True,
        "package_upgrade": True,
        "packages": ["docker.io", "docker-compose", "jq", "yq", "curl", "git", "python3-pip", "python3-yaml", "qemu-guest-agent"],
        "runcmd": runcmd,
        "write_files": write_files,
        "final_message": final_message,
    }

    return user_data_dict


def generate_meta_data(vmid: int, cluster_name: str) -> dict:
    """Generate the meta-data dictionary."""
    return {
        "instance-id": f"cloud-vm-{vmid}",
        "local-hostname": f"twinbox-mgmt-{cluster_name}",
    }


def write_yaml_file(data: dict, output_path: str) -> None:
    """Write data to YAML file with proper formatting."""
    with open(output_path, 'w') as f:
        yaml.dump(
            data,
            f,
            default_flow_style=False,
            sort_keys=False,
            width=120,
            allow_unicode=True
        )


def create_iso(user_data_path: str, meta_data_path: str, output_iso: str) -> None:
    """Create cloud-init ISO using cloud-localds or mkisofs."""
    iso_tmp = output_iso

    # Try cloud-localds first (preferred)
    try:
        result = subprocess.run(
            ["cloud-localds", "--disk-format", "raw", iso_tmp, user_data_path, meta_data_path],
            capture_output=True,
            text=True,
            check=True
        )
        print(f"Cloud-init ISO created using cloud-localds: {iso_tmp}")
        return
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    # Fallback to mkisofs
    try:
        result = subprocess.run(
            ["mkisofs", "-o", iso_tmp, "-volid", "cidata", "-joliet", "-rock", user_data_path, meta_data_path],
            capture_output=True,
            text=True,
            check=True
        )
        print(f"Cloud-init ISO created using mkisofs: {iso_tmp}")
        return
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    raise RuntimeError(
        "Failed to create cloud-init ISO. Install cloud-image-utils package for cloud-localds "
        "or genisoimage/mkisofs for ISO creation."
    )


def main():
    parser = argparse.ArgumentParser(
        description="Generate cloud-init configuration (ISO or snippet)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate ISO for VM creation
  export SSH_PUBLIC_KEY="ssh-rsa ..."
  export API_URL="https://pve:8006/api2/json"
  export API_TOKEN_SECRET="token-secret"
  python3 generate_cloudinit.py --type iso --cluster mycluster --output /tmp/cloud-init.iso

  # Generate snippet for snippet-based cloud-init
  python3 generate_cloudinit.py --type snippet --cluster mycluster --output /var/lib/vz/snippets/twinbox.yaml
"""
    )

    parser.add_argument(
        "--type",
        choices=["iso", "snippet"],
        required=True,
        help="Output type: iso (creates user-data + meta-data + ISO) or snippet (creates YAML only)"
    )

    parser.add_argument(
        "--cluster",
        required=True,
        help="Cluster name"
    )

    parser.add_argument(
        "--output",
        required=True,
        help="Output path (ISO file for --type iso, YAML file for --type snippet)"
    )

    parser.add_argument(
        "--vmid",
        type=int,
        help="VM ID for meta-data (required for --type iso)"
    )

    parser.add_argument(
        "--ssh-public-key",
        help="SSH public key (if not set, reads from SSH_PUBLIC_KEY env var)"
    )

    args = parser.parse_args()

    # Get configuration from environment or arguments
    ssh_public_key = args.ssh_public_key or os.getenv("SSH_PUBLIC_KEY")

    try:
        api_url = get_env_or_generate("API_URL", lambda: f"https://{os.uname().nodename}:8006/api2/json")
        api_token_secret = get_env_or_generate("API_TOKEN_SECRET", lambda: generate_password(64))
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Generate user-data
    print(f"Generating cloud-config for cluster: {args.cluster}")
    user_data_dict = generate_user_data(
        cluster_name=args.cluster,
        api_url=api_url,
        api_token_secret=api_token_secret,
        ssh_public_key=ssh_public_key
    )

    if args.type == "snippet":
        # Write snippet directly
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        write_yaml_file(user_data_dict, str(output_path))
        print(f"Snippet created: {output_path}")
        return

    # ISO mode requires vmid
    if args.vmid is None:
        print("Error: --vmid is required for --type iso", file=sys.stderr)
        sys.exit(1)

    # Create temporary directory for user-data and meta-data
    base_dir = Path(f"/tmp/cloud-init-{args.cluster}")
    base_dir.mkdir(parents=True, exist_ok=True)

    user_data_path = base_dir / "user-data"
    meta_data_path = base_dir / "meta-data"

    # Write user-data and meta-data
    write_yaml_file(user_data_dict, str(user_data_path))
    print(f"User-data written: {user_data_path}")

    meta_data_dict = generate_meta_data(args.vmid, args.cluster)
    write_yaml_file(meta_data_dict, str(meta_data_path))
    print(f"Meta-data written: {meta_data_path}")

    # Create ISO
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        create_iso(str(user_data_path), str(meta_data_path), str(output_path))
        print(f"ISO created successfully: {output_path}")

        # Also try to copy to Proxmox storage template directory
        storage_iso_path = Path("/var/lib/vz/template/iso") / output_path.name
        try:
            import shutil
            shutil.copy2(output_path, storage_iso_path)
            print(f"ISO copied to Proxmox storage: {storage_iso_path}")
        except Exception as e:
            print(f"Note: Could not copy to Proxmox storage: {e}", file=sys.stderr)

    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
