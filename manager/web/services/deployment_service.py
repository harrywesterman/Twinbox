"""
Deployment service for Twinbox.

Provides operations for monitoring and managing deployment executions:
- Get deployment status
- Stream deployment logs (SSE)
- Cancel deployments
"""

import logging
import time
from typing import Optional, Generator, List
from uuid import UUID
from datetime import datetime

from sqlalchemy.orm import Session
from sqlalchemy import desc

from manager.shared.database import Deployment, DeploymentLog, get_db

logger = logging.getLogger(__name__)


class DeploymentService:
    """
    Service for deployment-related operations.

    Handles status queries, log streaming, and deployment cancellation.
    """

    def __init__(self, db: Session):
        """
        Initialize deployment service.

        Args:
            db: SQLAlchemy database session
        """
        self.db = db

    def get_deployment_status(self, deployment_id: UUID) -> Optional[dict]:
        """
        Get deployment status with details.

        Args:
            deployment_id: Deployment UUID

        Returns:
            Dictionary with deployment status, started_at, completed_at, error_message, current_step,
            and progress. Returns None if deployment not found.
        """
        deployment = self.db.query(Deployment).filter(Deployment.id == deployment_id).first()
        if not deployment:
            return None

        return {
            "deployment_id": str(deployment.id),
            "cluster_id": str(deployment.cluster_id),
            "status": deployment.status,
            "deployment_type": deployment.deployment_type,
            "progress": float(deployment.progress),
            "current_step": deployment.current_step,
            "error_message": deployment.error_message,
            "started_at": deployment.started_at.isoformat() if deployment.started_at else None,
            "completed_at": deployment.completed_at.isoformat() if deployment.completed_at else None,
        }

    def stream_logs(
        self,
        deployment_id: UUID,
        limit: int = 100,
        offset: int = 0
    ) -> Generator[List[dict], None, None]:
        """
        Stream deployment logs via Server-Sent Events.

        This generator yields batches of log entries since the last poll.
        It implements a "hold-up" pattern: polls the database and yields only
        new logs that arrived since the previous poll.

        Args:
            deployment_id: Deployment UUID
            limit: Maximum number of log entries to return per poll
            offset: Number of most recent logs to skip (for pagination)

        Yields:
            Lists of log entry dictionaries (each with id, level, message, timestamp)

        Note:
            The caller should call time.sleep(1) between iterations to avoid
            excessive polling. This is a simple polling-based SSE implementation.
        """
        last_timestamp = None
        seen_ids = set()

        while True:
            # Query logs ordered by timestamp descending (newest first)
            query = self.db.query(DeploymentLog).filter(
                DeploymentLog.deployment_id == deployment_id
            ).order_by(desc(DeploymentLog.timestamp))

            # If we have a last timestamp, only get newer logs
            if last_timestamp:
                query = query.filter(DeploymentLog.timestamp > last_timestamp)

            # Apply limit and offset
            logs = query.limit(limit).offset(offset).all()

            # If we got logs, yield them
            new_logs = []
            for log in logs:
                if log.id not in seen_ids:
                    seen_ids.add(log.id)
                    new_logs.append({
                        "id": str(log.id),
                        "deployment_id": str(log.deployment_id),
                        "level": log.level,
                        "message": log.message,
                        "context": log.context or {},
                        "timestamp": log.timestamp.isoformat() if log.timestamp else None,
                    })
                    # Update last timestamp to newest seen
                    if last_timestamp is None or log.timestamp > last_timestamp:
                        last_timestamp = log.timestamp

            if new_logs:
                yield new_logs

            # Hold-up: sleep before next poll to avoid hammering database
            time.sleep(1)

    def get_logs(
        self,
        deployment_id: UUID,
        limit: int = 100,
        offset: int = 0
    ) -> List[dict]:
        """
        Get deployment logs as a static list.

        Args:
            deployment_id: Deployment UUID
            limit: Maximum number of log entries to return
            offset: Number of most recent logs to skip

        Returns:
            List of log entry dictionaries ordered by timestamp descending
        """
        logs = self.db.query(DeploymentLog).filter(
            DeploymentLog.deployment_id == deployment_id
        ).order_by(desc(DeploymentLog.timestamp)).limit(limit).offset(offset).all()

        return [
            {
                "id": str(log.id),
                "deployment_id": str(log.deployment_id),
                "level": log.level,
                "message": log.message,
                "context": log.context or {},
                "timestamp": log.timestamp.isoformat() if log.timestamp else None,
            }
            for log in logs
        ]

    def cancel_deployment(self, deployment_id: UUID) -> bool:
        """
        Cancel a running deployment.

        This marks the deployment as 'cancelled'. Background RQ jobs will
        notice the cancellation on their next check and exit gracefully.

        Args:
            deployment_id: Deployment UUID

        Returns:
            True if deployment was cancelled, False if not found or already completed
        """
        deployment = self.db.query(Deployment).filter(Deployment.id == deployment_id).first()
        if not deployment:
            logger.warning(f"Deployment {deployment_id} not found for cancellation")
            return False

        if deployment.status in ["success", "failed", "cancelled"]:
            logger.info(f"Deployment {deployment_id} already in terminal state: {deployment.status}")
            return False

        deployment.status = "cancelled"
        deployment.error_message = "Deployment cancelled by user"
        deployment.completed_at = None  # Will be set by onupdate

        # Update cluster status
        cluster = deployment.cluster
        if cluster and cluster.status == "provisioning":
            cluster.status = "error"  # Or "cancelled" if you add that status

        self.db.commit()
        logger.info(f"Cancelled deployment {deployment_id}")
        return True

    def list_deployments(self, cluster_id: Optional[UUID] = None) -> List[dict]:
        """
        List deployments with optional filter by cluster.

        Args:
            cluster_id: Optional cluster UUID filter

        Returns:
            List of deployment summary dictionaries
        """
        query = self.db.query(Deployment)
        if cluster_id:
            query = query.filter(Deployment.cluster_id == cluster_id)

        deployments = query.order_by(desc(Deployment.started_at)).all()

        return [
            {
                "deployment_id": str(d.id),
                "cluster_id": str(d.cluster_id),
                "status": d.status,
                "deployment_type": d.deployment_type,
                "progress": float(d.progress),
                "current_step": d.current_step,
                "started_at": d.started_at.isoformat() if d.started_at else None,
                "completed_at": d.completed_at.isoformat() if d.completed_at else None,
            }
            for d in deployments
        ]

    def get_deployment(self, deployment_id: UUID) -> Optional[Deployment]:
        """
        Get raw deployment ORM object.

        Args:
            deployment_id: Deployment UUID

        Returns:
            Deployment object or None
        """
        return self.db.query(Deployment).filter(Deployment.id == deployment_id).first()


# ========== Dependency Injection ==========

def get_deployment_service(db: Session = get_db()) -> DeploymentService:
    """
    FastAPI dependency to get DeploymentService instance.

    Args:
        db: Database session (injected by FastAPI)

    Returns:
        DeploymentService instance
    """
    return DeploymentService(db)
