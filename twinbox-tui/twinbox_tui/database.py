"""
SQLite database models and connection management for Twinbox TUI.

Simple, self-contained schema for tracking clusters and deployments.
"""

from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Float,
    Integer,
    String,
    Text,
    ForeignKey,
    create_engine,
)
from sqlalchemy.orm import declarative_base, sessionmaker, relationship

Base = declarative_base()


class Cluster(Base):
    """Cluster configuration and metadata."""

    __tablename__ = "clusters"

    id = Column(String, primary_key=True)  # UUID
    name = Column(String, nullable=False, unique=True)
    status = Column(String, nullable=False, default="pending")  # pending, installing, deployed, failed
    config_json = Column(Text, nullable=False)  # JSON serialized wizard config
    management_vm_id = Column(Integer, nullable=True)
    management_ip = Column(String, nullable=True)
    credentials_file = Column(String, nullable=True)  # Path to credentials file
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)

    # Relationships
    deployments = relationship("Deployment", back_populates="cluster", cascade="all, delete-orphan")


class Deployment(Base):
    """Deployment operation tracking."""

    __tablename__ = "deployments"

    id = Column(String, primary_key=True)  # UUID
    cluster_id = Column(String, ForeignKey("clusters.id", ondelete="CASCADE"), nullable=False)

    phase1_completed = Column(Boolean, default=False, nullable=False)
    phase2_completed = Column(Boolean, default=False, nullable=False)
    current_step = Column(Integer, default=0, nullable=False)
    progress = Column(Float, default=0.0, nullable=False)  # 0-100
    status = Column(String, nullable=False, default="running")  # running, success, failed, cancelled
    error_message = Column(Text, nullable=True)
    started_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    completed_at = Column(DateTime, nullable=True)

    # Relationships
    cluster = relationship("Cluster", back_populates="deployments")
    logs = relationship("DeploymentLog", back_populates="deployment", cascade="all, delete-orphan")


class DeploymentLog(Base):
    """Structured log entries for deployments."""

    __tablename__ = "deployment_logs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    deployment_id = Column(String, ForeignKey("deployments.id", ondelete="CASCADE"), nullable=False)

    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)
    level = Column(String, nullable=False)  # DEBUG, INFO, WARNING, ERROR, SUCCESS
    message = Column(Text, nullable=False)

    # Relationships
    deployment = relationship("Deployment", back_populates="logs")

    def __repr__(self) -> str:
        return f"<DeploymentLog {self.timestamp} [{self.level}] {self.message[:50]}>"


class PreflightResult(Base):
    """Preflight check results (cached)."""

    __tablename__ = "preflight_results"

    id = Column(Integer, primary_key=True, autoincrement=True)
    check_name = Column(String, nullable=False, unique=True)
    passed = Column(Boolean, nullable=False)
    message = Column(Text, nullable=True)
    checked_at = Column(DateTime, default=datetime.utcnow, nullable=False)


def create_engine_and_session(db_path: Path):
    """
    Create SQLAlchemy engine and session factory for given database path.

    Returns:
        tuple: (engine, SessionFactory)
    """
    # SQLite foreign key support
    def _enable_foreign_keys(dbapi_connection, connection_record):
        # SQLite foreign key constraints are disabled by default
        # Enabling them ensures cascade deletes work as expected
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    engine = create_engine(f"sqlite:///{db_path}", echo=False, future=True)
    from sqlalchemy import event

    # Enable foreign key constraints for SQLite (cascade deletes, etc.)
    @event.listens_for(engine, "connect")
    def _set_sqlite_pragma(dbapi_connection, connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    SessionFactory = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    return engine, SessionFactory


def init_db(db_path: Path) -> None:
    """
    Initialize database: create tables if they don't exist.

    Args:
        db_path: Path to SQLite database file
    """
    engine, _ = create_engine_and_session(db_path)
    Base.metadata.create_all(engine)
    engine.dispose()


class Database:
    """
    Database access layer for Twinbox TUI.

    Provides convenient methods for common operations without exposing ORM objects
    directly to UI layer if not needed.
    """

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.engine, self.SessionFactory = create_engine_and_session(db_path)

    def create_tables(self) -> None:
        """Create all tables if they don't exist."""
        Base.metadata.create_all(self.engine)

    def get_session(self):
        """Get a new session."""
        return self.SessionFactory()

    # Cluster operations
    def create_cluster(
        self,
        cluster_id: str,
        name: str,
        config_json: str,
        status: str = "pending",
        **kwargs,
    ) -> None:
        """Create a new cluster record."""
        with self.get_session() as session:
            cluster = Cluster(
                id=cluster_id,
                name=name,
                config_json=config_json,
                status=status,
                **kwargs,
            )
            session.add(cluster)
            session.commit()

    def get_cluster(self, cluster_id: str) -> Optional[Cluster]:
        """Get cluster by ID."""
        with self.get_session() as session:
            return session.get(Cluster, cluster_id)

    def list_clusters(self) -> list[Cluster]:
        """Get all clusters ordered by creation date (newest first)."""
        with self.get_session() as session:
            return session.query(Cluster).order_by(Cluster.created_at.desc()).all()

    def update_cluster(self, cluster_id: str, **kwargs) -> None:
        """Update cluster fields."""
        with self.get_session() as session:
            cluster = session.get(Cluster, cluster_id)
            if cluster:
                for key, value in kwargs.items():
                    setattr(cluster, key, value)
                session.commit()
            else:
                raise ValueError(f"Cluster {cluster_id} not found")

    def delete_cluster(self, cluster_id: str) -> None:
        """Delete cluster (cascades to deployments and logs)."""
        with self.get_session() as session:
            cluster = session.get(Cluster, cluster_id)
            if cluster:
                session.delete(cluster)
                session.commit()
            else:
                raise ValueError(f"Cluster {cluster_id} not found")

    # Deployment operations
    def create_deployment(self, deployment_id: str, cluster_id: str) -> None:
        """Create a new deployment record."""
        with self.get_session() as session:
            deployment = Deployment(
                id=deployment_id,
                cluster_id=cluster_id,
                status="running",
                current_step=0,
                progress=0.0,
            )
            session.add(deployment)
            session.commit()

    def get_deployment(self, deployment_id: str) -> Optional[Deployment]:
        """Get deployment by ID."""
        with self.get_session() as session:
            return session.get(Deployment, deployment_id)

    def get_current_deployment(self, cluster_id: str) -> Optional[Deployment]:
        """Get the latest deployment for a cluster."""
        with self.get_session() as session:
            query = (
                session.query(Deployment)
                .filter(Deployment.cluster_id == cluster_id)
                .order_by(Deployment.started_at.desc())
            )
            return query.first()

    def update_deployment(self, deployment_id: str, **kwargs) -> None:
        """Update deployment fields."""
        with self.get_session() as session:
            deployment = session.get(Deployment, deployment_id)
            if deployment:
                for key, value in kwargs.items():
                    setattr(deployment, key, value)
                session.commit()
            else:
                raise ValueError(f"Deployment {deployment_id} not found")

    def set_deployment_complete(self, deployment_id: str, success: bool, error: str = None) -> None:
        """Mark deployment as completed (success or failure)."""
        with self.get_session() as session:
            deployment = session.get(Deployment, deployment_id)
            if deployment:
                deployment.status = "success" if success else "failed"
                deployment.completed_at = datetime.utcnow()
                deployment.progress = 100.0 if success else deployment.progress
                if error:
                    deployment.error_message = error[:4096]  # limit length
                session.commit()

    # Logging operations
    def add_log(
        self, deployment_id: str, level: str, message: str, timestamp: datetime = None
    ) -> None:
        """Add a log entry to the database."""
        with self.get_session() as session:
            log = DeploymentLog(
                deployment_id=deployment_id,
                level=level.upper(),
                message=message,
                timestamp=timestamp or datetime.utcnow(),
            )
            session.add(log)
            session.commit()

    def get_logs(
        self, deployment_id: str, limit: int = 1000, level: str = None
    ) -> list[DeploymentLog]:
        """Get logs for a deployment, optionally filtered by level."""
        with self.get_session() as session:
            query = (
                session.query(DeploymentLog)
                .filter(DeploymentLog.deployment_id == deployment_id)
                .order_by(DeploymentLog.timestamp.asc())
            )
            if level:
                query = query.filter(DeploymentLog.level == level.upper())
            return query.limit(limit).all()

    # Preflight operations
    def save_preflight_check(self, check_name: str, passed: bool, message: str = None) -> None:
        """Save or update a preflight check result."""
        with self.get_session() as session:
            from sqlalchemy import update

            stmt = (
                update(PreflightResult)
                .where(PreflightResult.check_name == check_name)
                .values(passed=passed, message=message, checked_at=datetime.utcnow())
            )
            result = session.execute(stmt)
            if result.rowcount == 0:
                # Insert if not exists
                preflight = PreflightResult(
                    check_name=check_name,
                    passed=passed,
                    message=message,
                )
                session.add(preflight)
            session.commit()

    def get_preflight_results(self) -> list[PreflightResult]:
        """Get all preflight check results."""
        with self.get_session() as session:
            return session.query(PreflightResult).order_by(PreflightResult.checked_at.desc()).all()

    # Convenience: get cluster with deployment
    def get_cluster_with_latest_deployment(self, cluster_id: str) -> Optional[tuple[Cluster, Optional[Deployment]]]:
        """Get cluster and its most recent deployment."""
        cluster = self.get_cluster(cluster_id)
        if cluster:
            deployment = self.get_current_deployment(cluster_id)
            return cluster, deployment
        return None
