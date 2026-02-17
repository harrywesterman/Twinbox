"""
Tests for twinbox_tui.database module.

Uses an in-memory SQLite database for isolation.
"""

import pytest
from datetime import datetime
from pathlib import Path
from sqlalchemy import text

from twinbox_tui.database import (
    Base,
    Cluster,
    Deployment,
    DeploymentLog,
    Database,
    init_db,
)


@pytest.fixture
def temp_db(tmp_path):
    """Create a temporary database file."""
    db_path = tmp_path / "test.db"
    return db_path


@pytest.fixture
def db(temp_db):
    """Create a Database instance connected to temporary SQLite."""
    database = Database(temp_db)
    database.create_tables()
    yield database
    # Cleanup not needed - tmp_path is removed automatically


@pytest.fixture
def db_session(db):
    """Provide a session context manager for tests."""
    with db.get_session() as session:
        yield session
        session.rollback()  # Don't persist changes between tests


def test_init_db_creates_tables(temp_db):
    """Test that init_db creates all expected tables."""
    # Should not raise any errors
    init_db(temp_db)

    # Verify tables exist using raw SQLite connection
    import sqlite3
    conn = sqlite3.connect(temp_db)
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = {row[0] for row in cursor.fetchall()}
    conn.close()

    expected_tables = {"clusters", "deployments", "deployment_logs", "preflight_results"}
    assert expected_tables.issubset(tables)


def test_cluster_crud(db):
    """Test basic CRUD operations on Cluster model."""
    # Create
    cluster_id = "test-cluster-1"
    db.create_cluster(
        cluster_id=cluster_id,
        name="Test Cluster",
        config_json='{"test": "config"}',
        status="pending",
    )

    # Read
    cluster = db.get_cluster(cluster_id)
    assert cluster is not None
    assert cluster.name == "Test Cluster"
    assert cluster.status == "pending"
    assert cluster.config_json == '{"test": "config"}'

    # Update
    db.update_cluster(cluster_id, status="deployed", management_ip="192.168.1.100")
    cluster = db.get_cluster(cluster_id)
    assert cluster.status == "deployed"
    assert cluster.management_ip == "192.168.1.100"

    # List
    clusters = db.list_clusters()
    assert len(clusters) == 1
    assert clusters[0].id == cluster_id

    # Delete
    db.delete_cluster(cluster_id)
    assert db.get_cluster(cluster_id) is None


def test_deployment_lifecycle(db):
    """Test deployment creation, updates, and completion."""
    cluster_id = "cluster-for-deployment"
    db.create_cluster(
        cluster_id=cluster_id,
        name="Deployment Test Cluster",
        config_json="{}",
    )

    # Create deployment
    deployment_id = "deployment-1"
    db.create_deployment(deployment_id=deployment_id, cluster_id=cluster_id)

    # Verify initial state
    deployment = db.get_deployment(deployment_id)
    assert deployment is not None
    assert deployment.status == "running"
    assert deployment.progress == 0.0
    assert deployment.phase1_completed is False
    assert deployment.phase2_completed is False

    # Update progress
    db.update_deployment(deployment_id, progress=25.0, current_step=3)
    deployment = db.get_deployment(deployment_id)
    assert deployment.progress == 25.0
    assert deployment.current_step == 3

    # Mark phase 1 complete
    db.update_deployment(deployment_id, phase1_completed=True)
    deployment = db.get_deployment(deployment_id)
    assert deployment.phase1_completed is True

    # Complete successfully
    db.set_deployment_complete(deployment_id, success=True)
    deployment = db.get_deployment(deployment_id)
    assert deployment.status == "success"
    assert deployment.progress == 100.0
    assert deployment.completed_at is not None


def test_deployment_logging(db):
    """Test adding and retrieving deployment logs."""
    cluster_id = "cluster-logs"
    db.create_cluster(cluster_id=cluster_id, name="Log Test", config_json="{}")
    deployment_id = "deployment-logs"
    db.create_deployment(deployment_id=deployment_id, cluster_id=cluster_id)

    # Add logs
    db.add_log(deployment_id, "INFO", "Starting deployment")
    db.add_log(deployment_id, "WARNING", "Something look suspicious")
    db.add_log(deployment_id, "ERROR", "Oh no, an error occurred")
    db.add_log(deployment_id, "SUCCESS", "Deployment completed successfully")

    # Retrieve logs
    logs = db.get_logs(deployment_id)
    assert len(logs) == 4
    assert logs[0].level == "INFO"
    assert logs[1].level == "WARNING"
    assert logs[2].level == "ERROR"
    assert logs[3].level == "SUCCESS"

    # Filter by level
    error_logs = db.get_logs(deployment_id, level="ERROR")
    assert len(error_logs) == 1
    assert error_logs[0].message == "Oh no, an error occurred"

    # Limit
    limited_logs = db.get_logs(deployment_id, limit=2)
    assert len(limited_logs) == 2


def test_preflight_results(db):
    """Test saving and retrieving preflight check results."""
    # Save some checks
    db.save_preflight_check("proxmox_connection", True, "Connected successfully")
    db.save_preflight_check("nodes_available", True, "3 nodes online")
    db.save_preflight_check("storage_check", False, "Storage pool not found")

    # Retrieve all
    results = db.get_preflight_results()
    assert len(results) == 3

    # Check values
    check_map = {r.check_name: r for r in results}
    assert check_map["proxmox_connection"].passed is True
    assert check_map["proxmox_connection"].message == "Connected successfully"
    assert check_map["storage_check"].passed is False

    # Update existing check
    db.save_preflight_check("storage_check", True, "Storage pool created")
    results = db.get_preflight_results()
    check_map = {r.check_name: r for r in results}
    assert check_map["storage_check"].passed is True
    assert check_map["storage_check"].message == "Storage pool created"
    # Should still be only 3 records, not 4
    assert len(results) == 3


def test_get_current_deployment(db):
    """Test getting the latest deployment for a cluster."""
    cluster_id = "cluster-multi-deploy"
    db.create_cluster(cluster_id=cluster_id, name="Multi Deploy Test", config_json="{}")

    # Create two deployments
    db.create_deployment(deployment_id="dep1", cluster_id=cluster_id)
    db.add_log("dep1", "INFO", "First deployment")

    # Small delay to ensure different timestamps
    import time
    time.sleep(0.01)

    db.create_deployment(deployment_id="dep2", cluster_id=cluster_id)
    db.add_log("dep2", "INFO", "Second deployment")

    # Get current should return the latest (dep2)
    current = db.get_current_deployment(cluster_id)
    assert current is not None
    assert current.id == "dep2"

    # dep1 is older
    dep1 = db.get_deployment("dep1")
    dep2 = db.get_deployment("dep2")
    assert dep1.started_at < dep2.started_at


def test_cluster_deployment_relationship(db):
    """Test that we can get cluster and deployment together."""
    cluster_id = "cluster-rel-test"
    db.create_cluster(cluster_id=cluster_id, name="Relationship Test", config_json="{}")
    deployment_id = "dep-rel"
    db.create_deployment(deployment_id=deployment_id, cluster_id=cluster_id)

    result = db.get_cluster_with_latest_deployment(cluster_id)
    assert result is not None
    cluster, deployment = result
    assert cluster.id == cluster_id
    assert deployment is not None
    assert deployment.id == deployment_id


def test_delete_cluster_cascade(db):
    """Test that deleting a cluster cascades to deployments and logs."""
    cluster_id = "cluster-to-delete"
    db.create_cluster(cluster_id=cluster_id, name="Delete Me", config_json="{}")
    deployment_id = "dep-to-delete"
    db.create_deployment(deployment_id=deployment_id, cluster_id=cluster_id)
    db.add_log(deployment_id, "INFO", "Some log message")

    # Verify data exists
    assert db.get_cluster(cluster_id) is not None
    assert db.get_deployment(deployment_id) is not None
    logs = db.get_logs(deployment_id)
    assert len(logs) > 0

    # Delete cluster
    db.delete_cluster(cluster_id)

    # Verify cascade deletion
    assert db.get_cluster(cluster_id) is None
    assert db.get_deployment(deployment_id) is None
    logs = db.get_logs(deployment_id)  # Should return empty list or fail gracefully
    assert len(logs) == 0


def test_invalid_cluster_operations(db):
    """Test error handling for invalid cluster operations."""
    # Get non-existent cluster
    assert db.get_cluster("nonexistent") is None

    # Update non-existent cluster
    with pytest.raises(ValueError):
        db.update_cluster("nonexistent", status="deployed")

    # Delete non-existent cluster
    with pytest.raises(ValueError):
        db.delete_cluster("nonexistent")
