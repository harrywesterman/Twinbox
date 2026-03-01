#!/bin/bash
set -euo pipefail

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo ".env created from .env.example. Update values before continuing."
  exit 1
fi

if [[ -x scripts/install-management-tools.sh ]]; then
  sudo ./scripts/install-management-tools.sh --env-file .env
else
  echo "Missing scripts/install-management-tools.sh"
  exit 1
fi

docker compose pull
docker compose up -d

echo "Manager stack started"
echo "Web: http://localhost:3000"
echo "API: http://localhost:8080/api/health"
