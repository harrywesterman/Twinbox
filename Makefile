# Makefile for Twinbox testing

.PHONY: help test unit integration coverage clean install wizard-dev-run

help:
	@echo "Available targets:"
	@echo "  test        - Run all tests (unit + integration)"
	@echo "  unit        - Run unit tests only"
	@echo "  integration - Run integration tests only"
	@echo "  coverage    - Run tests with coverage report"
	@echo "  install     - Install test dependencies"
	@echo "  clean       - Clean up test artifacts"
	@echo "  wizard-dev-run - Upload local wizard to Proxmox and run it via SSH"

install:
	pip install -e .
	pip install pytest pytest-cov pytest-mock freezegun httpx sqlalchemy

test: unit integration

unit:
	@echo "Running unit tests..."
	pytest tests/unit -v --tb=short

integration:
	@echo "Running integration tests..."
	pytest tests/integration -v --tb=short

coverage:
	@echo "Running tests with coverage..."
	pytest tests/ --cov=twinbox.shared --cov-report=html --cov-report=term --cov=twinbox/shared/

clean:
	@echo "Cleaning test artifacts..."
	rm -rf .coverage htmlcov
	rm -rf *.db
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

test-watch:
	@echo "Running tests in watch mode..."
	pytest-watch tests/ -v

lint:
	@echo "Linting code..."
	# Add linting commands as needed (flake8, black, etc.)

wizard-dev-run:
	bash scripts/wizard-dev-run.sh
