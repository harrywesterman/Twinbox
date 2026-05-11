# Makefile for Twinbox testing

.PHONY: help test unit integration coverage clean install wizard-dev-run lint lint-fix format format-check

help:
	@echo "Available targets:"
	@echo "  test             - Run all tests (unit + integration)"
	@echo "  unit             - Run unit tests only"
	@echo "  integration      - Run integration tests only"
	@echo "  coverage         - Run tests with coverage report"
	@echo "  install          - Install test dependencies"
	@echo "  clean            - Clean up test artifacts"
	@echo "  lint             - Run linters (JS + Python)"
	@echo "  lint-fix         - Auto-fix lint issues"
	@echo "  format           - Format code (JS + Python)"
	@echo "  format-check     - Check formatting"
	@echo "  wizard-dev-run   - Upload local wizard to Proxmox and run it via SSH"

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
	@echo "Linting JavaScript..."
	npm run lint --prefix manager-api
	npm run lint --prefix manager-web
	npm run lint --prefix manager-worker
	npm run lint --prefix portal
	npx eslint lib/ scripts/
	@echo "Linting Python..."
	ruff check tests/

lint-fix:
	@echo "Auto-fixing JavaScript..."
	npm run lint:fix --prefix manager-api
	npm run lint:fix --prefix manager-web
	npm run lint:fix --prefix manager-worker
	npm run lint:fix --prefix portal
	npx eslint lib/ scripts/ --fix
	@echo "Auto-fixing Python..."
	ruff check --fix tests/

format:
	@echo "Formatting code..."
	npm run format --prefix manager-api
	npm run format --prefix manager-web
	npm run format --prefix manager-worker
	npm run format --prefix portal
	npx prettier --write "lib/**/*.{js,mjs}" "scripts/**/*.{js,mjs}"
	ruff format tests/

format-check:
	@echo "Checking formatting..."
	npm run format:check --prefix manager-api
	npm run format:check --prefix manager-web
	npm run format:check --prefix manager-worker
	npm run format:check --prefix portal
	npx prettier --check "lib/**/*.{js,mjs}" "scripts/**/*.{js,mjs}"
	ruff format --check tests/

wizard-dev-run:
	bash scripts/wizard-dev-run.sh
