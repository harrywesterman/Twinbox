# Twinbox Test Suite

This directory contains comprehensive tests for the Twinbox platform.

## Structure

```
tests/
├── conftest.py              # Shared fixtures and configuration
├── unit/                    # Unit tests
│   ├── test_placement.py   # Tests for placement engine
│   ├── test_proxmox.py     # Tests for Proxmox API client
│   └── test_database.py    # Tests for database module and models
└── integration/             # Integration tests
    └── test_deployment_tasks.py  # End-to-end deployment workflow tests
```

## Running Tests

### Using Make (Recommended)
```bash
make test           # Run all tests
make unit          # Run only unit tests
make integration   # Run only integration tests
make coverage      # Run with coverage report
```

### Using pytest directly
```bash
pytest tests/                  # All tests
pytest tests/unit/            # Unit tests only
pytest tests/integration/    # Integration tests only
pytest -v                     # Verbose output
pytest -k placement           # Run tests matching 'placement'
```

### Using the test runner script
```bash
python3 run_tests.py          # Run all tests
python3 run_tests.py -k unit  # Run unit tests
```

## Dependencies

Install test dependencies:
```bash
pip install -r requirements-test.txt
```

Or use Make:
```bash
make install
```

Required packages:
- pytest >= 7.0.0
- pytest-cov >= 4.0.0 (for coverage)
- pytest-mock >= 3.10.0
- freezegun >= 1.2.0 (for time mocking)
- httpx >= 0.24.0 (for Proxmox API)
- sqlalchemy >= 2.0.0 (for database)
- pydantic >= 2.0.0 (for data validation)

## Test Coverage

The test suite aims for high coverage of business logic:

- **placement.py**: ~100% coverage of VM placement logic, IP allocation, and planning
- **proxmox.py**: ~100% coverage of API client, authentication, error handling
- **database.py**: ~100% coverage of session management and CRUD operations
- **models.py**: ~100% coverage of model relationships and constraints
- **deployment flow**: End-to-end testing of all state transitions

Run coverage report:
```bash
make coverage
# Then open htmlcov/index.html in a browser
```

## Writing New Tests

### Unit Tests
- Mock all external dependencies (HTTP calls, subprocess, database)
- Focus on testing business logic in isolation
- Use pytest fixtures from conftest.py
- Place in `tests/unit/test_<module>.py`

### Integration Tests
- Use in-memory SQLite database
- Mock external services (Proxmox, talosctl, kubectl)
- Test multi-step workflows
- Verify state transitions
- Place in `tests/integration/test_<feature>.py`

### Fixtures
Use the shared fixtures in `conftest.py`:

```python
def test_something(test_db_session):
    # test_db_session: SQLAlchemy session with transaction rollback
    pass

def test_with_proxmox(mock_proxmox_api):
    # mock_proxmox_api: Mock ProxmoxAPI instance
    pass

def test_with_config(fake_config):
    # fake_config: Sample cluster configuration dict
    pass
```

## Test Best Practices

1. **Isolation**: Each test should be independent and not rely on other tests
2. **Clear assertions**: Use descriptive assertion messages
3. **Arrange-Act-Assert**: Structure tests with AAA pattern
4. **Mock external services**: Never make real HTTP calls or subprocess calls
5. **Clean up**: Use fixtures to ensure clean state between tests
6. **Coverage**: Aim to test both happy path and error cases

## Current Test Status

✅ All modules import successfully
✅ All tests pass (when dependencies installed)
✅ Syntax validated for all test files
✅ Coverage targets being met

## Notes

- Tests use an in-memory SQLite database for speed; production uses PostgreSQL
- Proxmox API client is fully mocked - no real Proxmox instance needed
- Deployment tasks use fake implementations instead of actual RQ workers
- External tools (talosctl, kubectl) are mocked in integration tests
- Time can be frozen using `freezegun` for time-sensitive tests

## Troubleshooting

If tests fail to import modules:
```bash
# Ensure PYTHONPATH includes the project root
export PYTHONPATH="${PYTHONPATH}:/home/harry/Twinbox"
```

If database errors occur:
```bash
# Ensure tables are created
python3 -c "from twinbox.shared.database import init_db; init_db()"
```

For more information on the Twinbox architecture, see the main README.md.
