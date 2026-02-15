"""
ORM Models for Twinbox Deployment System.

Defines all database models with proper relationships, indexes, and constraints.
Uses SQLAlchemy declarative base from database module.
"""

from datetime import datetime
from typing import Optional, List
from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    JSON,
    Index,
    UniqueConstraint,
    CheckConstraint,
)
from sqlalchemy.orm import declarative_base, relationship, Mapped, mapped_column
from sqlalchemy.dialects.postgresql import UUID, JSONB
import uuid

from .database import Base


class Cluster(Base):
    """
    Represents a Kubernetes cluster deployed via Twinbox.

    Stores cluster configuration, status, and metadata.
    """
    __tablename__ = "clusters"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        nullable=False,
    )
    name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        index=True,
    )
    description: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True,
    )
    # Status: pending, provisioning, ready, error, deleting
    status: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="pending",
        index=True,
    )
    # Version of Talos/Kubernetes
    talos_version: Mapped[Optional[str]] = mapped_column(
        String(50),
        nullable=True,
    )
    kubernetes_version: Mapped[Optional[str]] = mapped_column(
        String(50),
        nullable=True,
    )
    # Network configuration
    pod_cidr: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="10.244.0.0/16",
    )
    service_cidr: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="10.96.0.0/12",
    )
    # Cluster endpoint (VIP or load balancer)
    endpoint: Mapped[Optional[str]] = mapped_column(
        String(255),
        nullable=True,
    )
    # Kubeconfig data (encrypted)
    kubeconfig_encrypted: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True,
    )
    # Created/updated timestamps
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=datetime.utcnow,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
    )

    # Relationships
    vm_plans: Mapped[List["VMPlan"]] = relationship(
        "VMPlan",
        back_populates="cluster",
        cascade="all, delete-orphan",
    )
    deployments: Mapped[List["Deployment"]] = relationship(
        "Deployment",
        back_populates="cluster",
        cascade="all, delete-orphan",
    )
    cluster_states: Mapped[List["ClusterState"]] = relationship(
        "ClusterState",
        back_populates="cluster",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("name", name="uq_cluster_name"),
        Index("ix_cluster_status_created", "status", "created_at"),
    )

    def __repr__(self) -> str:
        return f"<Cluster(id={self.id}, name={self.name}, status={self.status})>"


class VMPlan(Base):
    """
    Represents a VM configuration plan for a cluster.

    Stores resource allocation and Proxmox-specific settings.
    """
    __tablename__ = "vm_plans"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        nullable=False,
    )
    cluster_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("clusters.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    role: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        comment="Role: 'control-plane' or 'worker'",
        index=True,
    )
    node_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=1,
    )
    # Resource specifications
    memory_mb: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment="Memory in MB",
    )
    cores: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment="Number of CPU cores",
    )
    disk_gb: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        comment="Disk size in GB",
    )
    # Proxmox-specific
    proxmox_node: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        comment="Target Proxmox node name",
    )
    vm_template: Mapped[Optional[str]] = mapped_column(
        String(255),
        nullable=True,
        comment="Template VM ID to clone from",
    )
    network_bridge: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="vmbr0",
    )
    storage: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        comment="Proxmox storage ID",
    )
    # Additional VM configuration as JSON
    extra_config: Mapped[Optional[dict]] = mapped_column(
        JSONB,
        nullable=True,
        default=dict,
    )

    # Relationships
    cluster: Mapped["Cluster"] = relationship(
        "Cluster",
        back_populates="vm_plans",
    )

    __table_args__ = (
        UniqueConstraint("cluster_id", "role", name="uq_vmplan_cluster_role"),
        Index("ix_vmplan_cluster_role", "cluster_id", "role"),
        CheckConstraint(
            "node_count > 0",
            name="ck_vmplan_node_count_positive"
        ),
        CheckConstraint(
            "memory_mb > 0 AND cores > 0 AND disk_gb > 0",
            name="ck_vmplan_resources_positive"
        ),
    )

    def __repr__(self) -> str:
        return f"<VMPlan(id={self.id}, cluster_id={self.cluster_id}, role={self.role}, count={self.node_count})>"


class Deployment(Base):
    """
    Represents a deployment operation for a cluster.

    Tracks the deployment workflow, status, and results.
    """
    __tablename__ = "deployments"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        nullable=False,
    )
    cluster_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("clusters.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    version: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        comment="Deployment version identifier",
    )
    # Status: pending, running, success, failed, cancelled
    status: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="pending",
        index=True,
    )
    # Deployment type: create, update, delete, reset
    deployment_type: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        index=True,
    )
    progress: Mapped[float] = mapped_column(
        Float,
        nullable=False,
        default=0.0,
        comment="Progress as percentage (0-100)",
    )
    current_step: Mapped[Optional[str]] = mapped_column(
        String(255),
        nullable=True,
        comment="Current deployment step",
    )
    error_message: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True,
    )
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=datetime.utcnow,
    )
    completed_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    # Relationships
    cluster: Mapped["Cluster"] = relationship(
        "Cluster",
        back_populates="deployments",
    )
    jobs: Mapped[List["Job"]] = relationship(
        "Job",
        back_populates="deployment",
        cascade="all, delete-orphan",
    )
    logs: Mapped[List["DeploymentLog"]] = relationship(
        "DeploymentLog",
        back_populates="deployment",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        Index("ix_deployment_cluster_status", "cluster_id", "status"),
        Index("ix_deployment_started", "started_at DESC"),
        CheckConstraint(
            "progress >= 0 AND progress <= 100",
            name="ck_deployment_progress_range"
        ),
    )

    def __repr__(self) -> str:
        return f"<Deployment(id={self.id}, cluster_id={self.cluster_id}, status={self.status}, progress={self.progress}%)>"


class Job(Base):
    """
    Represents a background job/task in the deployment system.

    Used for tracking async operations like VM creation, Talos bootstrap, etc.
    """
    __tablename__ = "jobs"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        nullable=False,
    )
    deployment_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("deployments.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    task_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        index=True,
        comment="Name of the task/function to execute",
    )
    # Status: pending, running, success, failed, retry
    status: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="pending",
        index=True,
    )
    priority: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        comment="Job priority (higher = more urgent)",
    )
    # Arguments and result serialized as JSON
    args: Mapped[Optional[dict]] = mapped_column(
        JSONB,
        nullable=True,
        default=dict,
    )
    result: Mapped[Optional[dict]] = mapped_column(
        JSONB,
        nullable=True,
    )
    error: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True,
    )
    # Retry tracking
    max_retries: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=3,
    )
    retry_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
    )
    # Timestamps
    queued_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=datetime.utcnow,
    )
    started_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    completed_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    # Relationships
    deployment: Mapped["Deployment"] = relationship(
        "Deployment",
        back_populates="jobs",
    )

    __table_args__ = (
        Index("ix_job_status_priority", "status", "priority DESC"),
        Index("ix_job_deployment", "deployment_id"),
        Index("ix_job_queued", "queued_at"),
        CheckConstraint(
            "priority >= 0",
            name="ck_job_priority_nonnegative"
        ),
        CheckConstraint(
            "retry_count >= 0 AND max_retries >= 0",
            name="ck_job_retries_nonnegative"
        ),
    )

    def __repr__(self) -> str:
        return f"<Job(id={self.id}, task={self.task_name}, status={self.status})>"


class DeploymentLog(Base):
    """
    Log entries for a deployment.

    Stores structured log messages with levels and timestamps.
    """
    __tablename__ = "deployment_logs"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        nullable=False,
    )
    deployment_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("deployments.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    level: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        comment="Log level: DEBUG, INFO, WARNING, ERROR",
        index=True,
    )
    message: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    # Structured data as JSON
    context: Mapped[Optional[dict]] = mapped_column(
        JSONB,
        nullable=True,
        default=dict,
    )
    timestamp: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=datetime.utcnow,
        index=True,
    )

    # Relationships
    deployment: Mapped["Deployment"] = relationship(
        "Deployment",
        back_populates="logs",
    )

    __table_args__ = (
        Index("ix_deployment_log_deployment_time", "deployment_id", "timestamp DESC"),
        Index("ix_deployment_log_level_time", "level", "timestamp DESC"),
    )

    def __repr__(self) -> str:
        return f"<DeploymentLog(id={self.id}, deployment_id={self.deployment_id}, level={self.level})>"


class ClusterState(Base):
    """
    Represents the cached state of a cluster.

    Stores snapshot of cluster state including nodes, pods, and health metrics.
    """
    __tablename__ = "cluster_states"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        nullable=False,
    )
    cluster_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("clusters.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    # State captured at this timestamp
    captured_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=datetime.utcnow,
    )
    # Node information
    node_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
    )
    ready_node_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
    )
    # Pod information
    pod_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
    )
    running_pod_count: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
    )
    # System information
    kubernetes_version: Mapped[Optional[str]] = mapped_column(
        String(50),
        nullable=True,
    )
    operating_system: Mapped[Optional[str]] = mapped_column(
        String(100),
        nullable=True,
    )
    architecture: Mapped[Optional[str]] = mapped_column(
        String(50),
        nullable=True,
    )
    # Node details serialized as JSON
    nodes: Mapped[Optional[dict]] = mapped_column(
        JSONB,
        nullable=True,
        default=dict,
    )
    # Health score (0-100)
    health_score: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Overall cluster health score",
    )
    # System metrics
    cpu_total: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Total CPU cores",
    )
    cpu_used: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Used CPU cores",
    )
    memory_total_mb: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Total memory in MB",
    )
    memory_used_mb: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Used memory in MB",
    )
    disk_total_gb: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Total disk in GB",
    )
    disk_used_gb: Mapped[Optional[float]] = mapped_column(
        Float,
        nullable=True,
        comment="Used disk in GB",
    )

    # Relationships
    cluster: Mapped["Cluster"] = relationship(
        "Cluster",
        back_populates="cluster_states",
    )

    __table_args__ = (
        Index("ix_cluster_state_cluster_captured", "cluster_id", "captured_at DESC"),
        Index("ix_cluster_state_captured", "captured_at DESC"),
        CheckConstraint(
            "node_count >= 0 AND ready_node_count >= 0",
            name="ck_clusterstate_nodes_nonnegative"
        ),
        CheckConstraint(
            "pod_count >= 0 AND running_pod_count >= 0",
            name="ck_clusterstate_pods_nonnegative"
        ),
        CheckConstraint(
            "health_score IS NULL OR (health_score >= 0 AND health_score <= 100)",
            name="ck_clusterstate_health_score_range"
        ),
    )

    def __repr__(self) -> str:
        return f"<ClusterState(id={self.id}, cluster_id={self.cluster_id}, nodes={self.node_count}, health={self.health_score})>"
