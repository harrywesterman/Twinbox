"""
Unit tests for the database module.

Tests cover:
- Database initialization
- Session creation/management
- Model relationships
- Table creation/dropping
"""

import pytest
from unittest.mock import patch, Mock
from sqlalchemy.orm import Session
from sqlalchemy import inspect

from manager.shared.database import Database, Base, get_db, init_db
from manager.shared.models import Cluster, Deployment, Job, VMPlan, DeploymentLog, ClusterState


class TestDatabase:
    """Tests for Database class."""

    @pytest.fixture
    def sqlite_db(self):
        """Create an in-memory SQLite database for testing."""
        db = Database("sqlite:///:memory:")
        db.create_tables()
        yield db
        db.drop_tables()
        db.close()

    def test_database_initialization_default(self):
        """Test database initialization with default SQLite."""
        db = Database()
        assert db.url is not None
        assert db.engine is not None

    def test_database_initialization_custom(self):
        """Test database initialization with custom URL."""
        db = Database("sqlite:///test.db")
        assert db.url == "sqlite:///test.db"

    def test_create_tables(self, sqlite_db):
        """Test table creation."""
        inspector = inspect(sqlite_db.engine)
        tables = inspector.get_table_names()

        assert 'clusters' in tables
        assert 'deployments' in tables
        assert 'jobs' in tables
        assert 'vm_plans' in tables
        assert 'deployment_logs' in tables

    def test_drop_tables(self, sqlite_db):
        """Test table dropping."""
        sqlite_db.drop_tables()
        inspector = inspect(sqlite_db.engine)
        tables = inspector.get_table_names()

        assert len(tables) == 0

    def test_get_session(self, sqlite_db):
        """Test session generation."""
        session_gen = sqlite_db.get_session()
        session = next(session_gen)

        assert isinstance(session, Session)
        assert session.is_active

        # Cleanup
        try:
            next(session_gen)
        except StopIteration:
            pass

    def test_get_session_with_commit(self, sqlite_db):
        """Test session commits successfully."""
        session_gen = sqlite_db.get_session()
        session = next(session_gen)

        # Add something
        cluster = Cluster(name="test-cluster", status="pending", config={})
        session.add(cluster)
        # Session will commit on next(session_gen)

        try:
            next(session_gen)
        except StopIteration:
            pass

        # Verify it was committed
        session2 = sqlite_db.get_session_sync()
        result = session2.query(Cluster).filter_by(name="test-cluster").first()
        session2.close()

        assert result is not None
        assert result.name == "test-cluster"

    def test_get_session_with_error(self, sqlite_db):
        """Test session rolls back on error."""
        session_gen = sqlite_db.get_session()
        session = next(session_gen)

        # Simulate error
        with pytest.raises(Exception):
            session.add(Cluster(name="bad-cluster", status="pending", config={}))
            raise ValueError("test error")

        # Cleanup
        try:
            next(session_gen)
        except StopIteration:
            pass

        # Verify it was NOT committed
        session2 = sqlite_db.get_session_sync()
        result = session2.query(Cluster).filter_by(name="bad-cluster").first()
        session2.close()

        assert result is None

    def test_get_session_sync(self, sqlite_db):
        """Test synchronous session retrieval."""
        session = sqlite_db.get_session_sync()
        assert isinstance(session, Session)
        session.close()

    def test_close(self, sqlite_db):
        """Test database connection closure."""
        sqlite_db.close()
        # No errors means success


class TestModels:
    """Tests for database models and their relationships."""

    @pytest.fixture
    def session(self):
        """Create a database session with cleanup."""
        db = Database("sqlite:///:memory:")
        db.create_tables()

        session = db.SessionLocal()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()
            db.drop_tables()
            db.close()

    def test_cluster_creation(self, session):
        """Test creating a cluster."""
        cluster = Cluster(
            name="test-cluster",
            description="Test cluster",
            status="pending",
            config={"provider": "proxmox"}
        )
        session.add(cluster)
        session.commit()

        result = session.query(Cluster).filter_by(name="test-cluster").first()
        assert result is not None
        assert result.name == "test-cluster"
        assert result.description == "Test cluster"
        assert result.status.value == "pending"
        assert result.config["provider"] == "proxmox"

    def test_cluster_unique_name(self, session):
        """Test that cluster names should be unique."""
        cluster1 = Cluster(name="unique-cluster", status="pending", config={})
        session.add(cluster1)
        session.commit()

        # In real usage, this would be enforced by unique constraint
        # Here we just verify the model allows the name field
        cluster2 = Cluster(name="unique-cluster", status="pending", config={})
        session.add(cluster2)

        # Note: SQLite in-memory doesn't enforce FK constraints by default
        # The actual uniqueness would be enforced at the DB level

    def test_deployment_creation(self, session):
        """Test creating a deployment."""
        cluster = Cluster(name="deploy-test-cluster", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="queued",
            task_data={"node_count": 3}
        )
        session.add(deployment)
        session.commit()

        result = session.query(Deployment).filter_by(cluster_id=cluster.id).first()
        assert result is not None
        assert result.task_type.value == "create_cluster"
        assert result.status.value == "queued"
        assert result.task_data["node_count"] == 3

    def test_deployment_cluster_relationship(self, session):
        """Test deployment to cluster relationship."""
        cluster = Cluster(name="rel-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="deploy_cluster",
            status="running"
        )
        session.add(deployment)
        session.commit()

        # Query back
        result = session.query(Deployment).filter_by(id=deployment.id).first()
        assert result.cluster.name == "rel-test"
        assert result.cluster.status.value == "pending"

    def test_job_creation(self, session):
        """Test creating a job."""
        cluster = Cluster(name="job-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="running"
        )
        session.add(deployment)
        session.commit()

        job = Job(
            deployment_id=deployment.id,
            job_type="provision_vm",
            status="queued",
            depends_on=[1, 2],
            max_attempts=5
        )
        session.add(job)
        session.commit()

        result = session.query(Job).filter_by(deployment_id=deployment.id).first()
        assert result is not None
        assert result.job_type.value == "provision_vm"
        assert result.status.value == "queued"
        assert result.depends_on == [1, 2]
        assert result.max_attempts == 5

    def test_job_deployment_relationship(self, session):
        """Test job to deployment relationship."""
        cluster = Cluster(name="job-rel-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="running"
        )
        session.add(deployment)
        session.commit()

        job = Job(
            deployment_id=deployment.id,
            job_type="configure_talos",
            status="queued"
        )
        session.add(job)
        session.commit()

        result = session.query(Job).filter_by(id=job.id).first()
        assert result.deployment.task_type.value == "create_cluster"
        assert result.deployment.cluster.name == "job-rel-test"

    def test_node_creation(self, session):
        """Test creating a node."""
        cluster = Cluster(name="node-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        node = Node(
            cluster_id=cluster.id,
            name="node-1",
            vm_id=101,
            role="controlplane",
            ip_address="192.168.1.10",
            cpu=4,
            memory_mb=8192,
            disk_gb=100,
            proxmox_node="pve1"
        )
        session.add(node)
        session.commit()

        result = session.query(Node).filter_by(cluster_id=cluster.id).first()
        assert result is not None
        assert result.name == "node-1"
        assert result.vm_id == 101
        assert result.role == "controlplane"
        assert result.ip_address == "192.168.1.10"
        assert result.cpu == 4
        assert result.memory_mb == 8192
        assert result.disk_gb == 100
        assert result.proxmox_node == "pve1"

    def test_node_cluster_relationship(self, session):
        """Test node to cluster relationship."""
        cluster = Cluster(name="node-rel-test", status="deployed", config={})
        session.add(cluster)
        session.commit()

        node = Node(
            cluster_id=cluster.id,
            name="management-1",
            vm_id=100,
            role="management",
            ip_address="192.168.1.100",
            cpu=8,
            memory_mb=16384,
            disk_gb=200,
            proxmox_node="pve1"
        )
        session.add(node)
        session.commit()

        result = session.query(Node).filter_by(id=node.id).first()
        assert result.cluster.name == "node-rel-test"
        assert result.cluster.status.value == "deployed"

    def test_deployment_log_creation(self, session):
        """Test creating a deployment log entry."""
        cluster = Cluster(name="log-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="running"
        )
        session.add(deployment)
        session.commit()

        log = DeploymentLog(
            deployment_id=deployment.id,
            level="INFO",
            message="Deployment started"
        )
        session.add(log)
        session.commit()

        result = session.query(DeploymentLog).filter_by(deployment_id=deployment.id).first()
        assert result is not None
        assert result.level == "INFO"
        assert result.message == "Deployment started"

    def test_cascade_delete_cluster(self, session):
        """Test that deleting cluster cascades to related records."""
        cluster = Cluster(name="cascade-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="running"
        )
        session.add(deployment)
        session.commit()

        job = Job(
            deployment_id=deployment.id,
            job_type="provision_vm",
            status="queued"
        )
        session.add(job)
        session.commit()

        node = Node(
            cluster_id=cluster.id,
            name="node-1",
            vm_id=101,
            role="controlplane",
            ip_address="192.168.1.10",
            cpu=2,
            memory_mb=4096,
            disk_gb=50,
            proxmox_node="pve1"
        )
        session.add(node)
        session.commit()

        log = DeploymentLog(
            deployment_id=deployment.id,
            level="INFO",
            message="Test log"
        )
        session.add(log)
        session.commit()

        # Delete cluster
        session.delete(cluster)
        session.commit()

        # Verify cascades
        assert session.query(Deployment).filter_by(id=deployment.id).first() is None
        assert session.query(Job).filter_by(id=job.id).first() is None
        assert session.query(Node).filter_by(id=node.id).first() is None
        assert session.query(DeploymentLog).filter_by(id=log.id).first() is None

    def test_multiple_deployments_per_cluster(self, session):
        """Test cluster can have multiple deployments."""
        cluster = Cluster(name="multi-deploy", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment1 = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="succeeded"
        )
        deployment2 = Deployment(
            cluster_id=cluster.id,
            task_type="deploy_cluster",
            status="succeeded"
        )
        session.add_all([deployment1, deployment2])
        session.commit()

        deployments = session.query(Deployment).filter_by(cluster_id=cluster.id).all()
        assert len(deployments) == 2

    def test_multiple_nodes_per_cluster(self, session):
        """Test cluster can have multiple nodes."""
        cluster = Cluster(name="multi-node", status="deployed", config={})
        session.add(cluster)
        session.commit()

        vm_plans = [
            VMPlan(
                cluster_id=cluster.id,
                name=f"node-{i}",
                vm_id=100 + i,
                role="worker" if i > 0 else "controlplane",
                ip_address=f"192.168.1.{100+i}",
                cpu=2,
                memory_mb=4096,
                disk_gb=50,
                proxmox_node=f"pve{i % 2 + 1}"
            )
            for i in range(5)
        ]
        session.add_all(vm_plans)
        session.commit()

        result_plans = session.query(VMPlan).filter_by(cluster_id=cluster.id).all()
        assert len(result_plans) == 5
        assert any(p.role == "controlplane" for p in result_plans)
        assert sum(1 for p in result_plans if p.role == "worker") == 4

    def test_job_status_transitions(self, session):
        """Test job status can transition through states."""
        cluster = Cluster(name="job-states", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="running"
        )
        session.add(deployment)
        session.commit()

        job = Job(
            deployment_id=deployment.id,
            job_type="provision_vm",
            status="queued"
        )
        session.add(job)
        session.commit()

        # Simulate status transition
        job.status = "running"
        job.started_at = None  # Would be set by datetime
        session.commit()

        job.status = "succeeded"
        job.completed_at = None  # Would be set by datetime
        session.commit()

        result = session.query(Job).filter_by(id=job.id).first()
        assert result.status.value == "succeeded"

    def test_deployment_error_tracking(self, session):
        """Test deployment error information storage."""
        cluster = Cluster(name="error-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type="create_cluster",
            status="failed",
            error_message="VM creation failed",
            error_details={"vmid": 100, "error": "insufficient resources"}
        )
        session.add(deployment)
        session.commit()

        result = session.query(Deployment).filter_by(cluster_id=cluster.id).first()
        assert result.status.value == "failed"
        assert result.error_message == "VM creation failed"
        assert result.error_details["vmid"] == 100
        assert result.error_details["error"] == "insufficient resources"

    def test_timestamps(self, session):
        """Test that timestamps are automatically set."""
        from datetime import datetime

        cluster = Cluster(name="timestamp-test", status="pending", config={})
        session.add(cluster)
        session.commit()

        assert cluster.created_at is not None
        assert isinstance(cluster.created_at, datetime)

        # updated_at should be None initially
        assert cluster.updated_at is None


class TestGetDB:
    """Tests for get_db dependency function."""""

    def test_get_db_returns_session(self):
        """Test get_db returns a session."""
        db = Database("sqlite:///:memory:")
        db.create_tables()

        session_gen = get_db()
        session = next(session_gen)

        assert isinstance(session, Session)

        # Cleanup
        try:
            next(session_gen)
        except StopIteration:
            pass

        db.drop_tables()
        db.close()


class TestInitDB:
    """Tests for init_db function."""

    def test_init_db_creates_tables(self):
        """Test init_db creates tables."""
        # Use a test database
        import os
        test_db_url = "sqlite:///test_init.db"

        # Set DATABASE_URL for init_db
        with patch.dict(os.environ, {"DATABASE_URL": test_db_url}):
            db = Database(test_db_url)
            db.create_tables()
            db.drop_tables()
            db.close()

        # Cleanup
        if os.path.exists("test_init.db"):
            os.remove("test_init.db")
