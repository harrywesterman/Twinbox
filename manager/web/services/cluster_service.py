"""
Cluster service for Twinbox.

Provides business logic for cluster management, including:
- Cluster CRUD operations
- Deployment plan generation
- Deployment orchestration with RQ jobs
"""

import logging
from typing import Optional, List, Dict, Any
from uuid import UUID

from sqlalchemy.orm import Session
from redis import Redis
from rq import Queue

from manager.shared.database import Cluster, VMPlan, Deployment, Job, DeploymentLog, get_db
from manager.shared.security import encrypt_credentials, decrypt_credentials
from manager.shared.placement import (
    discover_cluster_topology,
    optimize_placement,
    ClusterConfig,
    generate_vm_plan,
    validate_resources,
)
from manager.shared.proxmox import ProxmoxAPI

from .schemas import (
    ClusterCreate,
    ClusterResponse,
    VMPlan as VMPlanSchema,
    ReviewPlan,
    ResourceSummary,
)

logger = logging.getLogger(__name__)


class ClusterService:
    """
    Service for cluster-related operations.

    Handles cluster creation, retrieval, plan generation, and deployment initiation.
    """

    def __init__(self, db: Session):
        """
        Initialize cluster service.

        Args:
            db: SQLAlchemy database session
        """
        self.db = db

    def create_cluster(self, cluster_data: ClusterCreate) -> Cluster:
        """
        Create a new cluster record.

        Args:
            cluster_data: Cluster creation data from request

        Returns:
            Created Cluster ORM object

        Raises:
            ValueError: If cluster with same name already exists
            Exception: If database operation fails
        """
        # Check for existing cluster with same name
        existing = self.db.query(Cluster).filter(Cluster.name == cluster_data.name).first()
        if existing:
            raise ValueError(f"Cluster with name '{cluster_data.name}' already exists")

        # Encrypt Proxmox credentials
        encrypted_password = encrypt_credentials(cluster_data.proxmox_password)
        encrypted_ssh_key = None
        if cluster_data.proxmox_ssh_key:
            encrypted_ssh_key = encrypt_credentials(cluster_data.proxmox_ssh_key)

        # Create cluster record with all configuration
        cluster = Cluster(
            name=cluster_data.name,
            description=cluster_data.description,
            status="pending",
            pod_cidr="10.244.0.0/16",  # Default Calico CIDR
            service_cidr="10.96.0.0/12",  # Default Kubernetes service CIDR
            talos_version=cluster_data.talos_version,
            kubernetes_version=cluster_data.kubernetes_version,
            # Proxmox connection
            proxmox_host=cluster_data.proxmox_host,
            proxmox_user=cluster_data.proxmox_user,
            proxmox_password_encrypted=encrypted_password,
            proxmox_ssh_key_encrypted=encrypted_ssh_key,
            # Network settings
            network_bridge=cluster_data.network_bridge,
            network_cidr=cluster_data.network_cidr,
            network_gateway=cluster_data.network_gateway,
            ip_range_start=cluster_data.ip_range_start,
            ip_range_end=cluster_data.ip_range_end,
            dhcp_mode=cluster_data.dhcp_mode,
        )
        self.db.add(cluster)
        self.db.commit()
        self.db.refresh(cluster)

        logger.info(f"Created cluster: {cluster.id} ({cluster.name})")
        return cluster

    def get_cluster(self, cluster_id: UUID) -> Optional[Cluster]:
        """
        Get cluster by ID.

        Args:
            cluster_id: Cluster UUID

        Returns:
            Cluster if found, None otherwise
        """
        return self.db.query(Cluster).filter(Cluster.id == cluster_id).first()

    def get_cluster_by_name(self, name: str) -> Optional[Cluster]:
        """
        Get cluster by name.

        Args:
            name: Cluster name

        Returns:
            Cluster if found, None otherwise
        """
        return self.db.query(Cluster).filter(Cluster.name == name).first()

    def list_clusters(self) -> List[Cluster]:
        """
        List all clusters.

        Returns:
            List of all Cluster objects
        """
        return self.db.query(Cluster).order_by(Cluster.created_at.desc()).all()

    def generate_review_plan(self, cluster_id: UUID) -> ReviewPlan:
        """
        Generate deployment review plan for a cluster.

        This discovers the Proxmox topology, calculates resource requirements,
        and produces a complete VM placement plan for user review.

        Args:
            cluster_id: Cluster UUID

        Returns:
            ReviewPlan with VM plans, network config, and resource summary

        Raises:
            ValueError: If cluster not found
            Exception: If placement calculation fails
        """
        cluster = self.get_cluster(cluster_id)
        if not cluster:
            raise ValueError(f"Cluster {cluster_id} not found")

        # Get cluster configuration from VMPlan (management VM stores credentials)
        vm_plan = self.db.query(VMPlan).filter(
            VMPlan.cluster_id == cluster_id,
            VMPlan.role == "management"
        ).first()
        if not vm_plan:
            raise ValueError(f"No configuration found for cluster {cluster_id}")

        config_data = vm_plan.extra_config or {}

        # Decrypt Proxmox credentials
        try:
            proxmox_password = decrypt_credentials(config_data["proxmox_password_encrypted"])
            proxmox_ssh_key = None
            if config_data.get("proxmox_ssh_key_encrypted"):
                proxmox_ssh_key = decrypt_credentials(config_data["proxmox_ssh_key_encrypted"])
        except Exception as e:
            logger.error(f"Failed to decrypt credentials: {e}")
            raise ValueError("Failed to decrypt Proxmox credentials")

        # Connect to Proxmox
        try:
            proxmox_api = ProxmoxAPI(
                host=config_data["proxmox_host"],
                user=config_data["proxmox_user"],
                password=proxmox_password,
                verify_ssl=False  # TODO: Make configurable
            )
        except Exception as e:
            logger.error(f"Failed to connect to Proxmox: {e}")
            raise ValueError(f"Failed to connect to Proxmox: {e}")

        # Discover cluster topology
        try:
            topology = discover_cluster_topology(proxmox_api)
        except Exception as e:
            logger.error(f"Failed to discover topology: {e}")
            raise ValueError(f"Failed to discover Proxmox topology: {e}")

        if not topology.available_nodes:
            raise ValueError("No available Proxmox nodes found")

        # Build ClusterConfig
        cluster_config = ClusterConfig(
            num_controlplane=1,  # Default: single control plane for simplicity
            num_workers=0,  # Default: no workers initially
            network_bridge=config_data.get("network_bridge", "vmbr0"),
            network_cidr=config_data.get("network_cidr"),
            network_gateway=config_data.get("network_gateway"),
            ip_range_start=config_data.get("ip_range_start"),
            ip_range_end=config_data.get("ip_range_end"),
            dhcp_mode=config_data.get("dhcp_mode", True),
        )

        # Generate VM plan
        try:
            vm_plans = generate_vm_plan(cluster_config, topology)
        except Exception as e:
            logger.error(f"Failed to generate VM plan: {e}")
            raise ValueError(f"Failed to generate deployment plan: {e}")

        # Validate resources
        try:
            validate_resources(vm_plans, topology.available_nodes)
        except ValueError as e:
            raise ValueError(f"Resource validation failed: {e}")

        # Build resource summary
        total_cpu_available = sum(node.available_cpu for node in topology.available_nodes)
        total_ram_available = sum(node.available_ram_mb for node in topology.available_nodes)
        total_disk_available = sum(node.available_disk_gb for node in topology.available_nodes)

        total_cpu_needed = sum(vm.cpu for vm in vm_plans)
        total_ram_needed = sum(vm.ram_mb for vm in vm_plans)
        total_disk_needed = sum(vm.disk_gb for vm in vm_plans)

        resources = ResourceSummary(
            total_cpu_needed=total_cpu_needed,
            total_ram_needed=total_ram_needed,
            total_disk_needed=total_disk_needed,
            total_cpu_available=total_cpu_available,
            total_ram_available=total_ram_available,
            total_disk_available=total_disk_available,
            remaining_cpu=total_cpu_available - total_cpu_needed,
            remaining_ram_mb=total_ram_available - total_ram_needed,
            remaining_disk_gb=total_disk_available - total_disk_needed,
            num_controlplane=1,
            num_workers=0,
        )

        # Build network config
        network = {
            "bridge": cluster_config.network_bridge,
            "cidr": cluster_config.network_cidr,
            "gateway": cluster_config.network_gateway,
            "dhcp_mode": cluster_config.dhcp_mode,
            "ip_range": {
                "start": cluster_config.ip_range_start,
                "end": cluster_config.ip_range_end,
            } if not cluster_config.dhcp_mode else None,
        }

        # Convert VMPlan objects to schemas
        vm_plan_schemas = [
            VMPlanSchema(
                vm_name=vm.vm_name,
                role=vm.role,
                target_node=vm.target_node,
                cpu=vm.cpu,
                ram_mb=vm.ram_mb,
                disk_gb=vm.disk_gb,
                ip_address=vm.ip_address,
                bridge=vm.bridge,
                mac_address=vm.mac_address,
                iso=vm.iso,
            )
            for vm in vm_plans
        ]

        # Estimate duration (rough estimate: 30 min per VM + overhead)
        estimated_duration = len(vm_plans) * 1800 + 600

        return ReviewPlan(
            cluster_id=str(cluster_id),
            cluster_name=cluster.name,
            vm_plan=vm_plan_schemas,
            network=network,
            resources=resources,
            estimated_duration=estimated_duration,
        )

    def start_deployment(self, cluster_id: UUID) -> str:
        """
        Start cluster deployment by enqueuing RQ jobs.

        This creates a Deployment record and enqueues jobs in the correct order:
        1. discover_proxmox
        2. size_vms
        3. create_talos_vms
        4. wait_for_talos
        5. generate_talos_configs
        6. apply_talos_config
        7. bootstrap_kubernetes
        8. wait_for_workers
        9. install_cni
        10. install_metallb
        11. install_traefik
        12. deployment_complete

        Args:
            cluster_id: Cluster UUID

        Returns:
            Deployment UUID

        Raises:
            ValueError: If cluster not found or already deploying
            Exception: If job enqueuing fails
        """
        cluster = self.get_cluster(cluster_id)
        if not cluster:
            raise ValueError(f"Cluster {cluster_id} not found")

        if cluster.status in ["provisioning", "ready"]:
            raise ValueError(f"Cluster is already {cluster.status}")

        # Create deployment record
        deployment = Deployment(
            cluster_id=cluster_id,
            version="1.0",  # TODO: Use semantic versioning
            status="pending",
            deployment_type="create",
            progress=0.0,
        )
        self.db.add(deployment)
        self.db.commit()
        self.db.refresh(deployment)
        deployment_id = deployment.id

        # Update cluster status
        cluster.status = "provisioning"
        self.db.commit()

        # Enqueue jobs
        try:
            redis_url = self._get_redis_url()
            redis_conn = Redis.from_url(redis_url)
            queue = Queue(connection=redis_conn)
        except Exception as e:
            logger.error(f"Failed to connect to Redis: {e}")
            raise ValueError("Failed to connect to task queue")

        # Define job sequence
        job_sequence = [
            ("discover_proxmox", self._task_discover_proxmox),
            ("size_vms", self._task_size_vms),
            ("create_talos_vms", self._task_create_talos_vms),
            ("wait_for_talos", self._task_wait_for_talos),
            ("generate_talos_configs", self._task_generate_talos_configs),
            ("apply_talos_config", self._task_apply_talos_config),
            ("bootstrap_kubernetes", self._task_bootstrap_kubernetes),
            ("wait_for_workers", self._task_wait_for_workers),
            ("install_cni", self._task_install_cni),
            ("install_metallb", self._task_install_metallb),
            ("install_traefik", self._task_install_traefik),
            ("deployment_complete", self._task_deployment_complete),
        ]

        # Enqueue jobs with dependencies
        previous_job_id = None
        for step_name, task_func in job_sequence:
            job = queue.enqueue(
                task_func,
                args=(str(deployment_id),),
                job_id=f"{step_name}:{deployment_id}",
                depends_on=previous_job_id,
                timeout=3600,  # 1 hour timeout per job
            )
            previous_job_id = job.id

            # Log job enqueued
            log = DeploymentLog(
                deployment_id=deployment_id,
                level="INFO",
                message=f"Enqueued job: {step_name}",
                context={"job_id": job.id, "step": step_name},
            )
            self.db.add(log)

        self.db.commit()
        logger.info(f"Started deployment {deployment_id} for cluster {cluster_id}")
        return str(deployment_id)

    def _get_redis_url(self) -> str:
        """Get Redis connection URL from environment."""
        import os
        host = os.getenv("REDIS_HOST", "localhost")
        port = os.getenv("REDIS_PORT", "6379")
        db = os.getenv("REDIS_DB", "0")
        return f"redis://{host}:{port}/{db}"

    # ========== Task Functions (called by RQ workers) ==========

    def _task_discover_proxmox(self, deployment_id: str) -> Dict[str, Any]:
        """Discover Proxmox cluster topology."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Discovering Proxmox topology")
            # Implementation would use ProxmoxAPI
            # For now, return mock data
            topology = {
                "nodes": [
                    {"id": "pve1", "status": "online", "cpu": 8, "ram_gb": 64, "disk_gb": 1000},
                    {"id": "pve2", "status": "online", "cpu": 8, "ram_gb": 64, "disk_gb": 1000},
                ],
                "available_nodes": 2,
            }
            self._log_deployment(deployment_id, "INFO", "Discovered Proxmox topology", topology)
            self._update_progress(deployment_id, 10.0)
            return topology
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_size_vms(self, deployment_id: str) -> Dict[str, Any]:
        """Calculate VM resource requirements."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Sizing VMs")
            # In real implementation, would use placement engine
            vm_specs = {
                "management": {"cpu": 2, "ram_mb": 4096, "disk_gb": 32},
                "controlplane": {"cpu": 2, "ram_mb": 4096, "disk_gb": 50},
            }
            self._log_deployment(deployment_id, "INFO", "Calculated VM sizes", vm_specs)
            self._update_progress(deployment_id, 20.0)
            return vm_specs
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_create_talos_vms(self, deployment_id: str) -> Dict[str, Any]:
        """Create Talos VMs on Proxmox."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Creating Talos VMs")
            # In real implementation, would call ProxmoxAPI to create VMs
            created_vms = {
                "twinbox-mgmt-1": {"node": "pve1", "status": "created"},
                "talos-cp-1": {"node": "pve2", "status": "created"},
            }
            self._log_deployment(deployment_id, "INFO", "Created Talos VMs", created_vms)
            self._update_progress(deployment_id, 40.0)
            return created_vms
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_wait_for_talos(self, deployment_id: str) -> Dict[str, Any]:
        """Wait for Talos to boot and become ready."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Waiting for Talos to become ready")
            # In real implementation, would poll Talos API until ready
            self._log_deployment(deployment_id, "INFO", "Talos VMs ready")
            self._update_progress(deployment_id, 50.0)
            return {"status": "ready"}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_generate_talos_configs(self, deployment_id: str) -> Dict[str, Any]:
        """Generate Talos configuration files."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Generating Talos configurations")
            # In real implementation, would generate Talos configs with cluster secrets
            configs = {
                "controlplane": "generated talos config",
                "worker": "generated talos config",
            }
            self._log_deployment(deployment_id, "INFO", "Generated Talos configurations", configs)
            self._update_progress(deployment_id, 60.0)
            return configs
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_apply_talos_config(self, deployment_id: str) -> Dict[str, Any]:
        """Apply Talos configurations to nodes."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Applying Talos configurations")
            # In real implementation, would apply configs via Talos API
            self._log_deployment(deployment_id, "INFO", "Applied Talos configurations")
            self._update_progress(deployment_id, 70.0)
            return {"status": "applied"}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_bootstrap_kubernetes(self, deployment_id: str) -> Dict[str, Any]:
        """Bootstrap Kubernetes on control plane."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Bootstrapping Kubernetes")
            # In real implementation, would wait for control plane to be ready
            kubeconfig = "generated kubeconfig"
            self._log_deployment(deployment_id, "INFO", "Kubernetes bootstrapped", {"kubeconfig": kubeconfig})
            self._update_progress(deployment_id, 80.0)
            return {"kubeconfig": kubeconfig}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_wait_for_workers(self, deployment_id: str) -> Dict[str, Any]:
        """Wait for worker nodes to join cluster."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Waiting for worker nodes")
            # In real implementation, would wait for worker nodes to join
            self._log_deployment(deployment_id, "INFO", "Worker nodes joined")
            self._update_progress(deployment_id, 85.0)
            return {"workers_joined": True}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_install_cni(self, deployment_id: str) -> Dict[str, Any]:
        """Install CNI plugin (Flannel)."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Installing CNI plugin")
            # In real implementation, would apply Flannel manifests
            self._log_deployment(deployment_id, "INFO", "CNI plugin installed")
            self._update_progress(deployment_id, 90.0)
            return {"cni": "flannel", "status": "installed"}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_install_metallb(self, deployment_id: str) -> Dict[str, Any]:
        """Install MetalLB load balancer."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Installing MetalLB")
            # In real implementation, would apply MetalLB manifests
            self._log_deployment(deployment_id, "INFO", "MetalLB installed")
            self._update_progress(deployment_id, 93.0)
            return {"metallb": "installed"}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_install_traefik(self, deployment_id: str) -> Dict[str, Any]:
        """Install Traefik ingress controller."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Installing Traefik")
            # In real implementation, would apply Traefik manifests
            self._log_deployment(deployment_id, "INFO", "Traefik installed")
            self._update_progress(deployment_id, 96.0)
            return {"traefik": "installed"}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    def _task_deployment_complete(self, deployment_id: str) -> Dict[str, Any]:
        """Mark deployment as complete."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if not deployment:
            raise ValueError(f"Deployment {deployment_id} not found")

        try:
            self._update_step(deployment_id, "Completing deployment")
            deployment.status = "success"
            deployment.progress = 100.0
            deployment.completed_at = None  # Will be set by SQLAlchemy onupdate

            # Update cluster status
            cluster = self.db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
            if cluster:
                cluster.status = "ready"

            self.db.commit()
            self._log_deployment(deployment_id, "INFO", "Deployment completed successfully")
            return {"status": "success", "cluster_id": str(deployment.cluster_id)}
        except Exception as e:
            self._fail_deployment(deployment_id, str(e))
            raise

    # ========== Helper Methods ==========

    def _update_progress(self, deployment_id: str, progress: float) -> None:
        """Update deployment progress."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if deployment:
            deployment.progress = progress
            self.db.commit()

    def _update_step(self, deployment_id: str, step: str) -> None:
        """Update current deployment step."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if deployment:
            deployment.current_step = step
            self.db.commit()
        self._log_deployment(deployment_id, "INFO", step)

    def _log_deployment(self, deployment_id: str, level: str, message: str, context: Optional[dict] = None) -> None:
        """Add log entry to deployment."""
        log = DeploymentLog(
            deployment_id=UUID(deployment_id),
            level=level,
            message=message,
            context=context or {},
        )
        self.db.add(log)
        self.db.commit()

    def _fail_deployment(self, deployment_id: str, error_message: str) -> None:
        """Mark deployment as failed."""
        deployment = self.db.query(Deployment).filter(Deployment.id == UUID(deployment_id)).first()
        if deployment:
            deployment.status = "failed"
            deployment.error_message = error_message
            deployment.completed_at = None  # Will be set by SQLAlchemy onupdate
            self.db.commit()

        # Update cluster status
        cluster = self.db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
        if cluster:
            cluster.status = "error"

        self.db.commit()
        self._log_deployment(deployment_id, "ERROR", f"Deployment failed: {error_message}")


# ========== Dependency Injection ==========

def get_cluster_service(db: Session = get_db()) -> ClusterService:
    """
    FastAPI dependency to get ClusterService instance.

    Args:
        db: Database session (injected by FastAPI)

    Returns:
        ClusterService instance
    """
    return ClusterService(db)
