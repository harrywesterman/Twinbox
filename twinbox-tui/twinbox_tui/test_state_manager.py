"""
Tests for twinbox_tui.state_manager module.
"""

import pytest
from datetime import datetime
from pathlib import Path
import tempfile
from unittest.mock import MagicMock

from twinbox_tui.database import Database
from twinbox_tui.state_manager import StateManager


@pytest.fixture
def temp_db():
    """Create a temporary database."""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = Path(tmpdir) / "test.db"
        db = Database(db_path)
        db.create_tables()
        yield db


@pytest.fixture
def state_manager(temp_db):
    """Create StateManager with test database."""
    return StateManager(temp_db)


def test_create_and_get_cluster(state_manager):
    """Test creating a cluster and retrieving it."""
    config = {"node": "pve1", "cpu": 2, "ram_mb": 4096}
    cluster_id = state_manager.create_cluster(
        name="test-cluster",
        config=config,
        credentials_file="/path/to/creds.yaml",
    )

    cluster = state_manager.get_cluster(cluster_id)
    assert cluster is not None
    assert cluster["name"] == "test-cluster"
    assert cluster["status"] == "pending"
    assert cluster["config"] == config
    assert cluster["credentials_file"] == "/path/to/creds.yaml"
    assert cluster["management_vm_id"] is None
    assert cluster["management_ip"] is None


def test_update_cluster(state_manager):
    """Test updating cluster fields."""
    cluster_id = state_manager.create_cluster("updatable", {"test": "data"})

    # Update multiple fields
    state_manager.update_cluster(
        cluster_id,
        status="installing",
        management_vm_id=101,
        management_ip="192.168.1.100",
    )

    cluster = state_manager.get_cluster(cluster_id)
    assert cluster["status"] == "installing"
    assert cluster["management_vm_id"] == 101
    assert cluster["management_ip"] == "192.168.1.100"
    # Config should remain unchanged
    assert cluster["config"] == {"test": "data"}


def test_get_all_clusters(state_manager):
    """Test retrieving all clusters."""
    # Create multiple clusters
    ids = []
    for i in range(3):
        cid = state_manager.create_cluster(f"cluster-{i}", {"index": i})
        ids.append(cid)

    all_clusters = state_manager.get_all_clusters()
    # Should be 3 clusters
    assert len(all_clusters) == 3
    # Should be ordered by creation date descending (newest first)
    names = [c["name"] for c in all_clusters]
    assert "cluster-2" in names  # Most recent (higher index created later)
    assert "cluster-0" in names


def test_delete_cluster(state_manager):
    """Test cluster deletion."""
    cluster_id = state_manager.create_cluster("to-delete", {})
    assert state_manager.get_cluster(cluster_id) is not None

    state_manager.delete_cluster(cluster_id)
    assert state_manager.get_cluster(cluster_id) is None


def test_cluster_exists(state_manager):
    """Test cluster existence check."""
    cid = state_manager.create_cluster("exists", {})
    assert state_manager.cluster_exists("exists") is True
    assert state_manager.cluster_exists("not-exists") is False


def test_start_deployment(state_manager):
    """Test creating a deployment."""
    cluster_id = state_manager.create_cluster("deploy-test", {})

    deployment_id = state_manager.start_deployment(cluster_id)
    assert deployment_id is not None

    deployment = state_manager.get_deployment(deployment_id)
    assert deployment is not None
    assert deployment["cluster_id"] == cluster_id
    assert deployment["cluster_name"] == "deploy-test"
    assert deployment["status"] == "running"
    assert deployment["progress"] == 0.0
    assert deployment["phase1_completed"] is False
    assert deployment["phase2_completed"] is False


def test_update_deployment(state_manager):
    """Test updating deployment fields."""
    cluster_id = state_manager.create_cluster("update-deploy", {})
    deployment_id = state_manager.start_deployment(cluster_id)

    # Update various fields
    state_manager.update_deployment(
        deployment_id,
        progress=30.0,
        current_step=3,
        phase1_completed=True,
        status="running",  # Still running
    )

    deployment = state_manager.get_deployment(deployment_id)
    assert deployment["progress"] == 30.0
    assert deployment["current_step"] == 3
    assert deployment["phase1_completed"] is True
    assert deployment["status"] == "running"


def test_complete_deployment_success(state_manager):
    """Test marking deployment as successful."""
    cluster_id = state_manager.create_cluster("success-deploy", {})
    deployment_id = state_manager.start_deployment(cluster_id)

    state_manager.complete_deployment(deployment_id, success=True)

    deployment = state_manager.get_deployment(deployment_id)
    assert deployment["status"] == "success"
    assert deployment["progress"] == 100.0
    assert deployment["completed_at"] is not None
    assert deployment["error_message"] is None


def test_complete_deployment_failure(state_manager):
    """Test marking deployment as failed."""
    cluster_id = state_manager.create_cluster("fail-deploy", {})
    deployment_id = state_manager.start_deployment(cluster_id)

    state_manager.complete_deployment(
        deployment_id,
        success=False,
        error="Something went wrong"
    )

    deployment = state_manager.get_deployment(deployment_id)
    assert deployment["status"] == "failed"
    assert deployment["error_message"] == "Something went wrong"


def test_get_current_deployment(state_manager):
    """Test getting the latest deployment for a cluster."""
    cluster_id = state_manager.create_cluster("multi-deploy", {})

    # Create two deployments
    id1 = state_manager.start_deployment(cluster_id)
    import time
    time.sleep(0.01)  # Ensure different timestamps
    id2 = state_manager.start_deployment(cluster_id)

    current = state_manager.get_current_deployment(cluster_id)
    assert current is not None
    assert current["id"] == id2  # Should be the latest
    assert current["id"] != id1


def test_get_last_step_resume_checkpoint(state_manager):
    """Test getting checkpoint for resume."""
    cluster_id = state_manager.create_cluster("resume-test", {})
    deployment_id = state_manager.start_deployment(cluster_id)

    # Initially, all zeros
    step, p1, p2 = state_manager.get_last_step(deployment_id)
    assert step == 0
    assert p1 is False
    assert p2 is False

    # Simulate some progress
    state_manager.update_deployment(
        deployment_id,
        current_step=5,
        phase1_completed=True,
        phase2_completed=False,
    )

    step, p1, p2 = state_manager.get_last_step(deployment_id)
    assert step == 5
    assert p1 is True
    assert p2 is False


def test_logging_operations(state_manager):
    """Test adding and retrieving logs."""
    cluster_id = state_manager.create_cluster("log-test", {})
    deployment_id = state_manager.start_deployment(cluster_id)

    # Add logs at different levels
    state_manager.log(deployment_id, "INFO", "Starting deployment")
    state_manager.log(deployment_id, "WARNING", "Something odd")
    state_manager.log(deployment_id, "ERROR", "Oops, error!")
    state_manager.log(deployment_id, "SUCCESS", "All done")

    logs = state_manager.get_logs(deployment_id)
    assert len(logs) == 4
    assert logs[0]["level"] == "INFO"
    assert logs[1]["level"] == "WARNING"
    assert logs[2]["level"] == "ERROR"
    assert logs[3]["level"] == "SUCCESS"

    # Test filtering
    error_logs = state_manager.get_logs(deployment_id, level="ERROR")
    assert len(error_logs) == 1
    assert error_logs[0]["message"] == "Oops, error!"

    # Test limit
    limited = state_manager.get_logs(deployment_id, limit=2)
    assert len(limited) == 2


def test_preflight_results(state_manager):
    """Test saving and retrieving preflight checks."""
    # Save some checks
    state_manager.save_preflight_check("check1", True, "All good")
    state_manager.save_preflight_check("check2", False, "Not found")
    state_manager.save_preflight_check("check3", True, "OK")

    results = state_manager.get_preflight_results()
    assert len(results) == 3

    check_map = {r["check_name"]: r for r in results}
    assert check_map["check1"]["passed"] is True
    assert check_map["check2"]["passed"] is False
    assert check_map["check3"]["passed"] is True

    # Update existing check (should not increase count)
    state_manager.save_preflight_check("check2", True, "Fixed now")
    results = state_manager.get_preflight_results()
    assert len(results) == 3
    check_map = {r["check_name"]: r for r in results}
    assert check_map["check2"]["passed"] is True
    assert check_map["check2"]["message"] == "Fixed now"


def test_get_cluster_config(state_manager):
    """Test retrieving just the config."""
    config = {"key": "value", "nested": {"data": 123}}
    cluster_id = state_manager.create_cluster("config-test", config)

    retrieved = state_manager.get_cluster_config(cluster_id)
    assert retrieved == config

    # Non-existent cluster should return None
    assert state_manager.get_cluster_config("nonexistent") is None


def test_invalid_operations(state_manager):
    """Test error handling for invalid operations."""
    # Invalid cluster ID
    with pytest.raises(ValueError):
        state_manager.update_cluster("fake-id", status="active")

    with pytest.raises(ValueError):
        state_manager.delete_cluster("fake-id")

    # Invalid deployment ID
    with pytest.raises(ValueError):
        state_manager.update_deployment("fake-deploy", progress=50)
