"""
State Manager for Twinbox TUI.

High-level wrapper around the Database class providing domain-specific operations
and convenient methods for cluster and deployment state management.
"""

import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

from .config import get_config
from .database import Database, Cluster, Deployment, DeploymentLog, PreflightResult


class StateManager:
    """
    Manages cluster and deployment state with a convenient API.

    Wraps the Database class and provides:
    - UUID generation
    - Config serialization/deserialization
    - Deployment lifecycle tracking
    - Log streaming helpers
    """

    def __init__(self, db: Database):
        """
        Initialize StateManager with a Database instance.

        Args:
            db: Database instance
        """
        self.db = db

    def create_cluster(
        self,
        name: str,
        config: Dict[str, Any],
        credentials_file: Optional[str] = None,
        status: str = "pending",
    ) -> str:
        """
        Create a new cluster with generated UUID.

        Args:
            name: Cluster name (unique)
            config: Wizard configuration dictionary (will be JSON serialized)
            credentials_file: Optional path to Proxmox credentials file
            status: Initial status (pending, installing, etc.)

        Returns:
            cluster_id: UUID of created cluster
        """
        cluster_id = str(uuid.uuid4())
        import json

        self.db.create_cluster(
            cluster_id=cluster_id,
            name=name,
            config_json=json.dumps(config, indent=2),
            status=status,
            credentials_file=credentials_file,
        )
        return cluster_id

    def get_cluster(self, cluster_id: str) -> Optional[Dict[str, Any]]:
        """
        Get cluster as a dictionary.

        Args:
            cluster_id: Cluster UUID

        Returns:
            Dictionary with cluster data or None if not found
        """
        cluster = self.db.get_cluster(cluster_id)
        if not cluster:
            return None

        import json
        return {
            "id": cluster.id,
            "name": cluster.name,
            "status": cluster.status,
            "config": json.loads(cluster.config_json),
            "management_vm_id": cluster.management_vm_id,
            "management_ip": cluster.management_ip,
            "credentials_file": cluster.credentials_file,
            "created_at": cluster.created_at,
            "updated_at": cluster.updated_at,
        }

    def get_all_clusters(self) -> List[Dict[str, Any]]:
        """
        Get all clusters as dictionaries, newest first.

        Returns:
            List of cluster dictionaries
        """
        clusters = self.db.list_clusters()
        result = []
        for cluster in clusters:
            cluster_dict = self.get_cluster(cluster.id)
            if cluster_dict:
                result.append(cluster_dict)
        return result

    def update_cluster(
        self,
        cluster_id: str,
        status: Optional[str] = None,
        management_vm_id: Optional[int] = None,
        management_ip: Optional[str] = None,
        credentials_file: Optional[str] = None,
    ) -> None:
        """
        Update cluster fields.

        Args:
            cluster_id: Cluster UUID
            status: New status
            management_vm_id: VM ID after creation
            management_ip: IP address after VM boots
            credentials_file: Path to credentials (if set)

        Raises:
            ValueError: If cluster not found
        """
        updates = {}
        if status is not None:
            updates["status"] = status
        if management_vm_id is not None:
            updates["management_vm_id"] = management_vm_id
        if management_ip is not None:
            updates["management_ip"] = management_ip
        if credentials_file is not None:
            updates["credentials_file"] = credentials_file

        if updates:
            self.db.update_cluster(cluster_id, **updates)

    def delete_cluster(self, cluster_id: str) -> None:
        """
        Delete a cluster and all associated deployments/logs.

        Args:
            cluster_id: Cluster UUID

        Raises:
            ValueError: If cluster not found
        """
        self.db.delete_cluster(cluster_id)

    # Deployment operations

    def start_deployment(self, cluster_id: str) -> str:
        """
        Create a new deployment record for a cluster.

        Args:
            cluster_id: Cluster UUID

        Returns:
            deployment_id: UUID of created deployment
        """
        deployment_id = str(uuid.uuid4())
        self.db.create_deployment(deployment_id=deployment_id, cluster_id=cluster_id)
        return deployment_id

    def get_deployment(self, deployment_id: str) -> Optional[Dict[str, Any]]:
        """
        Get deployment as a dictionary.

        Args:
            deployment_id: Deployment UUID

        Returns:
            Dictionary with deployment data or None
        """
        deployment = self.db.get_deployment(deployment_id)
        if not deployment:
            return None

        cluster = self.db.get_cluster(deployment.cluster_id)
        return {
            "id": deployment.id,
            "cluster_id": deployment.cluster_id,
            "cluster_name": cluster.name if cluster else "Unknown",
            "phase1_completed": deployment.phase1_completed,
            "phase2_completed": deployment.phase2_completed,
            "current_step": deployment.current_step,
            "progress": deployment.progress,
            "status": deployment.status,
            "error_message": deployment.error_message,
            "started_at": deployment.started_at,
            "completed_at": deployment.completed_at,
        }

    def get_current_deployment(self, cluster_id: str) -> Optional[Dict[str, Any]]:
        """
        Get the most recent deployment for a cluster.

        Args:
            cluster_id: Cluster UUID

        Returns:
            Deployment dictionary or None if no deployments
        """
        deployment = self.db.get_current_deployment(cluster_id)
        if not deployment:
            return None

        return self.get_deployment(deployment.id)

    def update_deployment(
        self,
        deployment_id: str,
        *,
        phase1_completed: Optional[bool] = None,
        phase2_completed: Optional[bool] = None,
        current_step: Optional[int] = None,
        progress: Optional[float] = None,
        status: Optional[str] = None,
        error_message: Optional[str] = None,
    ) -> None:
        """
        Update deployment fields.

        Args:
            deployment_id: Deployment UUID
            phase1_completed: Mark phase 1 as complete
            phase2_completed: Mark phase 2 as complete
            current_step: Current step number
            progress: Progress percentage (0-100)
            status: Status string
            error_message: Error text if failed

        Raises:
            ValueError: If deployment not found
        """
        updates = {}
        if phase1_completed is not None:
            updates["phase1_completed"] = phase1_completed
        if phase2_completed is not None:
            updates["phase2_completed"] = phase2_completed
        if current_step is not None:
            updates["current_step"] = current_step
        if progress is not None:
            updates["progress"] = max(0.0, min(100.0, progress))  # Clamp 0-100
        if status is not None:
            updates["status"] = status
        if error_message is not None:
            updates["error_message"] = error_message

        if updates:
            self.db.update_deployment(deployment_id, **updates)

    def complete_deployment(self, deployment_id: str, success: bool, error: str = None) -> None:
        """
        Mark a deployment as completed (success or failure).

        Args:
            deployment_id: Deployment UUID
            success: True for success, False for failure
            error: Optional error message for failures
        """
        self.db.set_deployment_complete(deployment_id, success=success, error=error)

    def get_last_step(self, deployment_id: str) -> Tuple[int, bool, bool]:
        """
        Get checkpoint information for resuming a deployment.

        Args:
            deployment_id: Deployment UUID

        Returns:
            Tuple: (current_step, phase1_completed, phase2_completed)
        """
        deployment = self.db.get_deployment(deployment_id)
        if not deployment:
            return (0, False, False)
        return (
            deployment.current_step,
            deployment.phase1_completed,
            deployment.phase2_completed,
        )

    # Logging operations

    def log(
        self,
        deployment_id: str,
        level: str,
        message: str,
        timestamp: datetime = None,
    ) -> None:
        """
        Add a log entry to the database.

        Args:
            deployment_id: Deployment UUID
            level: Log level (INFO, WARNING, ERROR, SUCCESS, DEBUG)
            message: Log message
            timestamp: Optional timestamp (defaults to now)
        """
        self.db.add_log(deployment_id, level, message, timestamp=timestamp)

    def get_logs(
        self,
        deployment_id: str,
        limit: int = 1000,
        level: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        """
        Get logs for a deployment.

        Args:
            deployment_id: Deployment UUID
            limit: Maximum number of logs to return
            level: Optional filter by level

        Returns:
            List of log dictionaries with keys: id, timestamp, level, message
        """
        logs = self.db.get_logs(deployment_id, limit=limit, level=level)
        return [
            {
                "id": log.id,
                "timestamp": log.timestamp,
                "level": log.level,
                "message": log.message,
            }
            for log in logs
        ]

    # Preflight operations

    def save_preflight_check(self, check_name: str, passed: bool, message: str = None) -> None:
        """
        Save or update a preflight check result.

        Args:
            check_name: Unique check identifier
            passed: Whether check passed
            message: Optional descriptive message
        """
        self.db.save_preflight_check(check_name, passed, message)

    def get_preflight_results(self) -> List[Dict[str, Any]]:
        """
        Get all preflight check results.

        Returns:
            List of check result dictionaries
        """
        results = self.db.get_preflight_results()
        return [
            {
                "check_name": r.check_name,
                "passed": r.passed,
                "message": r.message,
                "checked_at": r.checked_at,
            }
            for r in results
        ]

    # Convenience helpers

    def cluster_exists(self, name: str) -> bool:
        """
        Check if a cluster with given name exists.

        Args:
            name: Cluster name

        Returns:
            True if cluster exists
        """
        for cluster in self.db.list_clusters():
            if cluster.name == name:
                return True
        return False

    def get_cluster_config(self, cluster_id: str) -> Optional[Dict[str, Any]]:
        """
        Get just the config dictionary for a cluster.

        Args:
            cluster_id: Cluster UUID

        Returns:
            Config dict or None
        """
        cluster_data = self.get_cluster(cluster_id)
        return cluster_data["config"] if cluster_data else None

    # Helper for listing deployments (for logs screen)

    def list_deployments_for_cluster(self, cluster_id: str) -> List[Dict[str, Any]]:
        """
        Get all deployments for a cluster.

        Args:
            cluster_id: Cluster UUID

        Returns:
            List of deployment dicts
        """
        deployments = self.db.list_deployments_for_cluster(cluster_id)
        result = []
        for dep in deployments:
            result.append({
                "id": dep.id,
                "cluster_id": dep.cluster_id,
                "current_step": dep.current_step,
                "progress": dep.progress,
                "status": dep.status,
                "error_message": dep.error_message,
                "started_at": dep.started_at,
                "completed_at": dep.completed_at,
            })
        return result
