"""
Database models for Twinbox.
"""

from sqlalchemy import Column, Integer, String, DateTime, Text, Boolean, JSON, Enum as SQLEnum, ForeignKey
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
import enum
from .database import Base


class ClusterStatus(enum.Enum):
    """Status of a cluster."""
    PENDING = "pending"
    DEPLOYING = "deploying"
    DEPLOYED = "deployed"
    FAILED = "failed"
    DELETING = "deleting"
    DELETED = "deleted"


class DeploymentStatus(enum.Enum):
    """Status of a deployment."""
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"


class JobType(enum.Enum):
    """Type of background job."""
    CREATE_CLUSTER = "create_cluster"
    DEPLOY_CLUSTER = "deploy_cluster"
    DELETE_CLUSTER = "delete_cluster"
    PROVISION_VM = "provision_vm"
    CONFIGURE_TALOS = "configure_talos"
    BOOTSTRAP_K8S = "bootstrap_k8s"
    INSTALL_ADDONS = "install_addons"
    HEALTH_CHECK = "health_check"


class Cluster(Base):
    """Cluster model representing a Talos Kubernetes cluster."""

    __tablename__ = "clusters"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), unique=True, nullable=False, index=True)
    description = Column(Text, nullable=True)
    status = Column(SQLEnum(ClusterStatus), default=ClusterStatus.PENDING, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    # Cluster configuration
    config = Column(JSON, nullable=False, default=dict)

    # Relationships
    deployments = relationship("Deployment", back_populates="cluster", cascade="all, delete-orphan")
    nodes = relationship("Node", back_populates="cluster", cascade="all, delete-orphan")

    def __repr__(self) -> str:
        return f"<Cluster(id={self.id}, name={self.name}, status={self.status})>"


class Deployment(Base):
    """Deployment model tracking a single deployment/operation."""

    __tablename__ = "deployments"

    id = Column(Integer, primary_key=True, index=True)
    cluster_id = Column(Integer, ForeignKey("clusters.id"), nullable=False)
    task_type = Column(SQLEnum(JobType), nullable=False)
    status = Column(SQLEnum(DeploymentStatus), default=DeploymentStatus.QUEUED, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    started_at = Column(DateTime(timezone=True), nullable=True)
    completed_at = Column(DateTime(timezone=True), nullable=True)

    # Error tracking
    error_message = Column(Text, nullable=True)
    error_details = Column(JSON, nullable=True)

    # Task-specific data
    task_data = Column(JSON, default=dict)

    # Relationships
    cluster = relationship("Cluster", back_populates="deployments")
    jobs = relationship("Job", back_populates="deployment", cascade="all, delete-orphan")

    def __repr__(self) -> str:
        return f"<Deployment(id={self.id}, cluster={self.cluster_id}, status={self.status})>"


class Job(Base):
    """Individual job/step within a deployment."""

    __tablename__ = "jobs"

    id = Column(Integer, primary_key=True, index=True)
    deployment_id = Column(Integer, ForeignKey("deployments.id"), nullable=False)
    job_type = Column(SQLEnum(JobType), nullable=False)
    status = Column(SQLEnum(DeploymentStatus), default=DeploymentStatus.QUEUED, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    started_at = Column(DateTime(timezone=True), nullable=True)
    completed_at = Column(DateTime(timezone=True), nullable=True)

    # Job result
    result = Column(JSON, nullable=True)
    error_message = Column(Text, nullable=True)

    # Retry tracking
    attempts = Column(Integer, default=0)
    max_attempts = Column(Integer, default=3)

    # Dependencies
    depends_on = Column(JSON, default=list)  # List of job IDs

    # Relationships
    deployment = relationship("Deployment", back_populates="jobs")

    def __repr__(self) -> str:
        return f"<Job(id={self.id}, type={self.job_type}, status={self.status})>"


class Node(Base):
    """Proxmox node model."""

    __tablename__ = "nodes"

    id = Column(Integer, primary_key=True, index=True)
    cluster_id = Column(Integer, ForeignKey("clusters.id"), nullable=False)
    name = Column(String(100), nullable=False)
    vm_id = Column(Integer, nullable=False)
    role = Column(String(50), nullable=False)  # 'management', 'controlplane', 'worker'
    ip_address = Column(String(50), nullable=True)

    # VM specifications
    cpu = Column(Integer, nullable=False)
    memory_mb = Column(Integer, nullable=False)
    disk_gb = Column(Integer, nullable=False)

    # Node assignment
    proxmox_node = Column(String(100), nullable=False)

    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    # Relationships
    cluster = relationship("Cluster", back_populates="nodes")

    # Indexes
    __table_args__ = (
        # Unique constraint: (cluster_id, vm_id) and (cluster_id, name)
    )

    def __repr__(self) -> str:
        return f"<Node(id={self.id}, name={self.name}, role={self.role}, vm_id={self.vm_id})>"


class DeploymentLog(Base):
    """Log entries for deployments."""

    __tablename__ = "deployment_logs"

    id = Column(Integer, primary_key=True, index=True)
    deployment_id = Column(Integer, ForeignKey("deployments.id"), nullable=False, index=True)
    job_id = Column(Integer, ForeignKey("jobs.id"), nullable=True, index=True)
    level = Column(String(20), nullable=False)  # 'INFO', 'WARN', 'ERROR', 'DEBUG'
    message = Column(Text, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    # Relationships
    __table_args__ = (
        # Index on deployment_id, created_at for fast log retrieval
    )

    def __repr__(self) -> str:
        return f"<DeploymentLog(id={self.id}, level={self.level}, message={self.message[:50]})>"
