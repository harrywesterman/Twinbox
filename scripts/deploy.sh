#!/bin/bash
# Development deployment script for Twinbox Manager

set -e  # Exit on any error

echo "========================================"
echo "Twinbox Manager Development Deploy"
echo "========================================"

# Check if docker and docker-compose are installed
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed"
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
    echo "Error: docker-compose is not installed"
    exit 1
fi

# Navigate to manager directory
cd "$(dirname "$0")/.."

# Build Docker images
echo ""
echo "Building Docker images..."
docker-compose -f manager/docker-compose.yml build

# Run database migrations (if alembic is configured)
echo ""
echo "Running database migrations..."
if [ -f "manager/web/alembic.ini" ]; then
    docker-compose -f manager/docker-compose.yml run --rm web alembic upgrade head
else
    echo "Alembic not configured yet, skipping migrations..."
fi

# Start services
echo ""
echo "Starting services..."
docker-compose -f manager/docker-compose.yml up -d

# Wait for services to be healthy
echo ""
echo "Waiting for services to be ready..."
sleep 10

# Show service status
echo ""
echo "Service status:"
docker-compose -f manager/docker-compose.yml ps

echo ""
echo "========================================"
echo "Deployment complete!"
echo "========================================"
echo ""
echo "Web UI: http://localhost:8080"
echo ""
echo "To view logs:"
echo "  docker-compose -f manager/docker-compose.yml logs -f web"
echo "  docker-compose -f manager/docker-compose.yml logs -f worker"
echo ""
echo "To stop:"
echo "  docker-compose -f manager/docker-compose.yml down"
echo ""
