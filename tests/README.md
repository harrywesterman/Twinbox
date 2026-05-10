# Tests

Test suite for the current manager-first runtime.

## Scope

- `tests/api/`: API contract and file-persistence behavior
- `tests/worker/`: worker queue lifecycle behavior
- `tests/scripts/`: shell script argument/env validation
- `tests/portal/`: Portal component and integration tests

## Run

```bash
python3 -m pip install -r requirements-test.txt
python3 -m pytest -q tests
```

## Notes

- Tests target `manager-api`, `manager-worker`, and `scripts/manager`.
- Legacy `manager.shared` architecture tests were removed.
