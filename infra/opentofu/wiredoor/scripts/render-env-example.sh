#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
# Example Wiredoor .env values this stack tries to set/update

ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=change-me
VPN_PUBLIC_HOST=wiredoor.example.com
VPN_PORT=51820
TCP_SERVICES_PORT_RANGE=32760-32767
EOF