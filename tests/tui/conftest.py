"""
Test fixtures for TUI tests.
"""

import pytest
from pathlib import Path

# Configure test environment
@pytest.fixture(scope="session", autouse=True)
def setup_test_environment(tmp_path_factory):
    """Set up test environment variables and paths."""
    # Create a temporary data directory for tests
    test_data = tmp_path_factory.mktemp("twinbox-test-data")
    test_config = tmp_path_factory.mktemp("twinbox-test-config")

    # Set environment variables that the app might read
    import os
    os.environ["TWINBOX_TEST_MODE"] = "1"
    os.environ["TWINBOX_DATA_DIR"] = str(test_data)
    os.environ["TWINBOX_CONFIG_DIR"] = str(test_config)

    yield

    # Cleanup (tmp_path_factory handles automatic cleanup)


# No session-scoped fixtures needed beyond environment setup
