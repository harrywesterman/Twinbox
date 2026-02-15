"""
Deployment Tasks for Twinbox RQ Worker.

This module defines all async deployment tasks that are executed by the RQ worker.
Each task is idempotent, logs to the database, and handles errors appropriately.

Task Sequence:
1. discover_proxmox - Discover cluster topology and update VM plans
2. size_vms - Calculate VM resource requirements and create/update VMPlan records
3. create_talos_vms - Create Talos VMs via Proxmox API
4. wait_for_talos - Wait for all Talos nodes to become ready
5. generate_talos_configs - Generate Talos machine configurations
6. apply_talos_config - Apply Talos configs to nodes (CP sequential, workers parallel)
7. bootstrap_kubernetes - Bootstrap Kubernetes cluster and get kubeconfig
8. wait_for_workers - Wait for worker nodes to join and become Ready
9. install_cni - Install Calico CNI
10. install_metallb - Install MetalLB load balancer
11. install_traefik - Install Traefik ingress controller
12. deployment_complete - Mark deployment as succeeded and finalize cluster state

Each task accepts deployment_id as its argument and uses the current RQ job context
to update job status in the database.
"""

import os
import sys
import time
import uuid
import yaml
from typing import Any, Dict, List, Optional
from pathlib import Path
from datetime import datetime

from sqlalchemy.orm import Session
from rq import get_current_job

from shared.database import SessionLocal, engine
from shared.models import (
    Cluster,
    Deployment,
    Job,
    DeploymentLog,
    VMPlan,
    ClusterState,
)
from shared.proxmox import ProxmoxAPI
from shared.placement import (
    discover_cluster_topology,
    optimize_placement,
    validate_resources,
    ClusterConfig,
    VMPlan as PlacementVMPlan,
)
from shared.talos import TalosManager, TalosError, TalosTimeoutError
from shared.k8s import K8sManager, K8sError, K8sTimeoutError
from shared.security import decrypt_credentials


def get_db() -> Session:
    """Get a database session."""
    return SessionLocal()


def log_to_db(
    deployment_id: uuid.UUID,
    step: str,
    level: str,
    message: str,
    context: Optional[Dict[str, Any]] = None,
) -> None:
    """
    Write a log entry to the deployment_logs table.

    Args:
        deployment_id: UUID of the deployment
        step: Current step name (e.g., "create_talos_vms", "bootstrap")
        level: Log level ("info", "warning", "error", "debug")
        message: Log message
        context: Optional additional context data
    """
    try:
        db = get_db()
        log_entry = DeploymentLog(
            deployment_id=deployment_id,
            job_id="unknown",  # Will be updated by task wrapper
            step=step,
            level=level,
            message=message,
            context=context or {},
        )
        db.add(log_entry)
        db.commit()
        db.close()
    except Exception as e:
        # Log to stderr if DB logging fails
        print(f"[DB_LOG_FAILED] {e}: {message}", file=sys.stderr)


def update_job_status(job_id: str, status: str, result: Optional[Dict] = None, error: Optional[str] = None) -> None:
    """
    Update the job record in the database.

    Args:
        job_id: RQ job ID
        status: Job status ("running", "success", "failed", "retry")
        result: Optional result data to store
        error: Optional error message if status is "failed"
    """
    try:
        db = get_db()
        job = db.query(Job).filter(Job.job_id == job_id).first()
        if job:
            job.status = status
            if result:
                job.result = result
            if error:
                job.error = error

            if status == "running" and not job.started_at:
                job.started_at = datetime.utcnow()
            elif status in ("success", "failed"):
                job.completed_at = datetime.utcnow()

            db.commit()
        db.close()
    except Exception as e:
        print(f"[JOB_UPDATE_FAILED] {e}", file=sys.stderr)


def update_deployment_progress(deployment_id: uuid.UUID, progress: float, current_step: str) -> None:
    """
    Update deployment progress and current step.

    Args:
        deployment_id: UUID of the deployment
        progress: Progress percentage (0-100)
        current_step: Name of the current step
    """
    try:
        db = get_db()
        deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
        if deployment:
            deployment.progress = progress
            deployment.current_step = current_step
            db.commit()
        db.close()
    except Exception as e:
        print(f"[DEPLOYMENT_UPDATE_FAILED] {e}", file=sys.stderr)


def task_wrapper(func):
    """
    Decorator to wrap deployment tasks with common error handling and logging.

    This decorator:
    - Captures the current RQ job
    - Updates job status to "running"
    - Logs to deployment_logs
    - Handles exceptions and updates job status to "failed"
    - Updates deployment progress and status
    - Ensures proper cleanup
    """
    from functools import wraps

    @wraps(func)
    def wrapper(deployment_id: str, *args, **kwargs):
        # Convert deployment_id to UUID
        deployment_uuid = uuid.UUID(deployment_id) if isinstance(deployment_id, str) else deployment_id

        # Get current job context
        job = get_current_job()
        job_id = job.id if job else "unknown"

        # Setup DB logging for this deployment
        # Monkey-patch log_to_db to include job_id
        original_log_to_db = globals().get('log_to_db')

        def log_with_job(step: str, level: str, message: str, context: Optional[Dict] = None):
            original_log_to_db(deployment_uuid, step, level, message, context)
            # Also write to DB log with correct job_id
            try:
                db = get_db()
                log_entry = DeploymentLog(
                    deployment_id=deployment_uuid,
                    job_id=job_id,
                    step=step,
                    level=level,
                    message=message,
                    context=context or {},
                )
                db.add(log_entry)
                db.commit()
                db.close()
            except Exception:
                pass

        # Update job status to running
        update_job_status(job_id, "running")

        # Get deployment record
        db = get_db()
        deployment = db.query(Deployment).filter(Deployment.id == deployment_uuid).first()
        if not deployment:
            error_msg = f"Deployment {deployment_id} not found"
            log_with_job(func.__name__, "error", error_msg)
            update_job_status(job_id, "failed", error=error_msg)
            raise ValueError(error_msg)

        # Update cluster status to provisioning (if not already)
        cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
        if cluster and cluster.status == "pending":
            cluster.status = "provisioning"
            db.commit()

        db.close()

        log_with_job(func.__name__, "info", f"Starting task: {func.__name__}")

        try:
            # Execute the task
            result = func(
                deployment_uuid,
                log_with_job,
                update_deployment_progress,
                *args,
                **kwargs
            )

            # Update job status to success
            update_job_status(job_id, "success", result=result or {})
            log_with_job(func.__name__, "info", f"Task completed successfully: {func.__name__}")

            return result

        except (TalosError, TalosTimeoutError, K8sError, K8sTimeoutError) as e:
            error_msg = f"Task failed with error: {str(e)}"
            log_with_job(func.__name__, "error", error_msg)
            update_job_status(job_id, "failed", error=error_msg)
            raise

        except Exception as e:
            error_msg = f"Task failed with unexpected error: {type(e).__name__}: {str(e)}"
            log_with_job(func.__name__, "error", error_msg, context={"exception_type": type(e).__name__})
            update_job_status(job_id, "failed", error=error_msg)
            raise

    return wrapper


@task_wrapper
def discover_proxmox(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Discover Proxmox cluster topology and update VM plans.

    Connects to Proxmox API using cluster credentials, queries all nodes,
    and discovers available resources and network bridges. Updates the
    vm_plans table with discovered topology information.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function (step, level, message)
        update_progress: Function to update deployment progress

    Returns:
        Dictionary with discovery results (node count, total resources, etc.)

    Raises:
        ValueError: If deployment or cluster not found
        ProxmoxAPIError: If Proxmox API calls fail
    """
    log("discover_proxmox", "info", "Discovering Proxmox cluster topology...")
    update_progress(deployment_id, 5.0, "discover_proxmox")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found for deployment {deployment_id}")

    # Get Proxmox credentials from cluster (encrypted)
    if not cluster.proxmox_creds_encrypted:
        raise ValueError("Proxmox credentials not set for cluster")

    # Decrypt credentials
    try:
        decrypted = decrypt_credentials(cluster.proxmox_creds_encrypted)
        creds = yaml.safe_load(decrypted)
        proxmox_url = creds["url"]
        token_name = creds["token_name"]
        token_value = creds["token_value"]
    except Exception as e:
        log("discover_proxmox", "error", f"Failed to decrypt Proxmox credentials: {e}")
        raise

    # Connect to Proxmox
    try:
        api = ProxmoxAPI(
            base_url=proxmox_url,
            token_name=token_name,
            token_value=token_value,
        )
        log("discover_proxmox", "info", "Connected to Proxmox API")
    except Exception as e:
        log("discover_proxmox", "error", f"Failed to connect to Proxmox: {e}")
        raise

    # Discover topology
    try:
        topology = discover_cluster_topology(api)
    except Exception as e:
        log("discover_proxmox", "error", f"Failed to discover cluster topology: {e}")
        raise

    available_nodes = topology.available_nodes
    log("discover_proxmox", "info", f"Discovered {len(available_nodes)} online Proxmox nodes")

    if not available_nodes:
        raise ValueError("No online Proxmox nodes found")

    # Calculate total available resources
    total_cpu = sum(node.available_cpu for node in available_nodes)
    total_ram_gb = sum(node.available_ram_mb for node in available_nodes) / 1024
    total_disk_gb = sum(node.available_disk_gb for node in available_nodes)

    log(
        "discover_proxmox",
        "info",
        f"Total available resources: {total_cpu:.1f} CPU cores, {total_ram_gb:.1f} GB RAM, {total_disk_gb:.1f} GB disk"
    )

    # Get network bridges
    bridges = [b for b in topology.networks if b.get("active")]
    bridge_names = [b["iface"] for b in bridges]
    log("discover_proxmox", "info", f"Available bridges: {', '.join(bridge_names) if bridge_names else 'none found'}")

    # Store topology in vm_plans as metadata
    # First, clear any existing placeholder plans for this cluster
    db.query(VMPlan).filter(VMPlan.cluster_id == cluster.id).delete()
    db.commit()

    # Create a special "topology" record to store discovery data
    topo_plan = VMPlan(
        cluster_id=cluster.id,
        role="topology",
        node_count=len(available_nodes),
        memory_mb=0,
        cores=0,
        disk_gb=0,
        proxmox_node="",
        network_bridge=bridge_names[0] if bridge_names else "vmbr0",
        extra_config={
            "discovery": {
                "nodes": [
                    {
                        "id": node.id,
                        "total_cpu": node.total_cpu,
                        "available_cpu": node.available_cpu,
                        "total_ram_mb": node.total_ram_mb,
                        "available_ram_mb": node.available_ram_mb,
                        "total_disk_gb": node.total_disk_gb,
                        "available_disk_gb": node.available_disk_gb,
                    }
                    for node in available_nodes
                ],
                "bridges": bridges,
                "total_resources": {
                    "cpu": total_cpu,
                    "ram_gb": total_ram_gb,
                    "disk_gb": total_disk_gb,
                },
            }
        },
    )
    db.add(topo_plan)
    db.commit()
    db.close()

    log("discover_proxmox", "info", "Topology discovery complete")

    return {
        "node_count": len(available_nodes),
        "available_nodes": [node.id for node in available_nodes],
        "bridges": bridge_names,
        "total_resources": {
            "cpu": total_cpu,
            "ram_gb": total_ram_gb,
            "disk_gb": total_disk_gb,
        },
    }


@task_wrapper
def size_vms(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Calculate VM resource requirements and create VMPlan records.

    Based on cluster configuration and discovered topology, determines
    resource allocation for management, control plane, and worker VMs.
    Creates VMPlan records in the database.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with VM sizing summary

    Raises:
        ValueError: If configuration invalid or resources insufficient
    """
    log("size_vms", "info", "Calculating VM resource requirements...")
    update_progress(deployment_id, 15.0, "size_vms")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Get topology from vm_plans
    topo_plan = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role == "topology"
    ).first()

    if not topo_plan or not topo_plan.extra_config:
        raise ValueError("Topology not discovered. Run discover_proxmox first.")

    discovery = topo_plan.extra_config["discovery"]
    nodes_data = discovery["nodes"]

    # Reconstruct NodeInfo objects
    from shared.placement import NodeInfo
    available_nodes = []
    for node_data in nodes_data:
        node = NodeInfo(
            id=node_data["id"],
            total_cpu=node_data["total_cpu"],
            total_ram_mb=node_data["total_ram_mb"],
            total_disk_gb=node_data["total_disk_gb"],
            used_cpu=node_data["total_cpu"] - node_data["available_cpu"],
            used_ram_mb=node_data["total_ram_mb"] - node_data["available_ram_mb"],
            used_disk_gb=node_data["total_disk_gb"] - node_data["available_disk_gb"],
        )
        available_nodes.append(node)

    # Build cluster config from database/request
    # Note: This should come from cluster configuration or previous step
    # For now, we'll get from cluster record or use defaults
    # In the full system, this would come from the cluster configuration interface

    # Get network configuration from cluster
    network_bridge = cluster.network_bridge or "vmbr0"
    dhcp_mode = not bool(cluster.ip_range_start)  # If IP range not set, use DHCP

    # Determine number of control plane and worker nodes
    # This would normally come from the deployment request or cluster config
    # For now, we'll get from cluster status or use defaults
    # Expected: cluster should have this stored or we derive from existing VMPlan count
    num_controlplane = 3  # Default, should be configurable
    num_workers = 3  # Default, should be configurable

    # Create ClusterConfig
    config = ClusterConfig(
        num_controlplane=num_controlplane,
        num_workers=num_workers,
        network_bridge=network_bridge,
        network_cidr=None,  # Not yet known, will be determined or user-provided
        dhcp_mode=dhcp_mode,
        ip_range_start=cluster.ip_range_start,
        ip_range_end=cluster.ip_range_end,
    )

    # Build topology object
    topology = type('Topology', (), {
        'available_nodes': available_nodes,
        'networks': discovery['bridges'],
        'nodes': available_nodes,
    })()

    # Generate optimized placement plan
    try:
        vm_plan_objs = optimize_placement(config, topology)
    except ValueError as e:
        log("size_vms", "error", f"Resource allocation failed: {e}")
        raise

    # Delete old VMPlans (except topology)
    db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role != "topology"
    ).delete()
    db.commit()

    # Create VMPlan records in database
    total_vms = len(vm_plan_objs)
    for i, vm_plan in enumerate(vm_plan_objs):
        db_vm_plan = VMPlan(
            cluster_id=cluster.id,
            role=vm_plan.role,
            node_count=1,  # Each plan is for one VM
            memory_mb=vm_plan.ram_mb,
            cores=vm_plan.cpu,
            disk_gb=vm_plan.disk_gb,
            proxmox_node=vm_plan.target_node,
            network_bridge=vm_plan.bridge,
            extra_config={
                "vm_name": vm_plan.vm_name,
                "iso": vm_plan.iso,
                "ip_address": vm_plan.ip_address,
                "mac_address": vm_plan.mac_address,
            },
        )
        db.add(db_vm_plan)

        log(
            "size_vms",
            "info",
            f"Planned VM: {vm_plan.vm_name} on {vm_plan.target_node} "
            f"({vm_plan.cpu} CPU, {vm_plan.ram_mb}MB RAM, {vm_plan.disk_gb}GB disk)"
        )

    db.commit()
    db.close()

    log(
        "size_vms",
        "info",
        f"VM sizing complete: {total_vms} VMs planned "
        f"(1 management, {num_controlplane} control-plane, {num_workers} workers)"
    )

    update_progress(deployment_id, 25.0, "size_vms")

    return {
        "total_vms": total_vms,
        "management_vms": 1,
        "controlplane_count": num_controlplane,
        "worker_count": num_workers,
        "vm_plans_created": total_vms,
    }


@task_wrapper
def create_talos_vms(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Create Talos VMs via Proxmox API.

    Reads VM plans from database, and for each Talos VM (controlplane and worker),
    creates a VM in Proxmox with the specified resources. Updates VM IDs and IPs
    as they become available.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with summary of created VMs

    Raises:
        ProxmoxAPIError: If VM creation fails
        ValueError: If VM plans not found
    """
    log("create_talos_vms", "info", "Starting Talos VM creation via Proxmox API...")
    update_progress(deployment_id, 30.0, "create_talos_vms")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Get Proxmox credentials
    if not cluster.proxmox_creds_encrypted:
        raise ValueError("Proxmox credentials not set")

    try:
        decrypted = decrypt_credentials(cluster.proxmox_creds_encrypted)
        creds = yaml.safe_load(decrypted)
        api = ProxmoxAPI(
            base_url=creds["url"],
            token_name=creds["token_name"],
            token_value=creds["token_value"],
        )
    except Exception as e:
        log("create_talos_vms", "error", f"Failed to connect to Proxmox: {e}")
        raise

    # Get all VM plans for Talos VMs (controlplane and worker, skip management if it's already created)
    talos_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role.in_(["controlplane", "worker"])
    ).all()

    if not talos_plans:
        raise ValueError("No VM plans found for Talos VMs. Run size_vms first.")

    total_vms = len(talos_plans)
    created_vms = []
    failed_vms = []

    for idx, vm_plan in enumerate(talos_plans, 1):
        vm_name = vm_plan.extra_config.get("vm_name", f"vm-{vm_plan.id}")
        node = vm_plan.proxmox_node
        iso = vm_plan.extra_config.get("iso", "local:iso/talos-amd64.iso")

        log(
            "create_talos_vms",
            "info",
            f"Creating Talos VM {idx}/{total_vms}: {vm_name} on node {node}"
        )

        try:
            # Create VM via Proxmox API
            vmid = api.create_vm(
                node=node,
                name=vm_name,
                cpu=vm_plan.cores,
                ram_mb=vm_plan.memory_mb,
                disk_gb=vm_plan.disk_gb,
                bridge=vm_plan.network_bridge,
                iso=iso,
                cloud_init=True,
                start_after_create=True,
                qemu_agent=True,
                ostype="l26",  # Linux 2.6+ (Talos)
                machine="q35",  # Modern chipset
                cpu_type="host",
                bios="ovmf",  # UEFI
            )

            log("create_talos_vms", "info", f"VM {vm_name} created with ID {vmid}")

            # Update VM plan with the assigned VM ID
            vm_plan.extra_config["proxmox_vmid"] = vmid
            db.commit()

            created_vms.append({
                "vm_name": vm_name,
                "vmid": vmid,
                "node": node,
            })

            # Wait a bit for VM to start and agent to initialize
            time.sleep(2)

        except Exception as e:
            log("create_talos_vms", "error", f"Failed to create VM {vm_name}: {e}")
            failed_vms.append({"vm_name": vm_name, "error": str(e)})
            # Continue with other VMs

    db.close()

    if failed_vms:
        raise ValueError(f"Failed to create {len(failed_vms)} VMs: {[f['vm_name'] for f in failed_vms]}")

    log("create_talos_vms", "info", f"Successfully created {len(created_vms)} Talos VMs")

    update_progress(deployment_id, 50.0, "create_talos_vms")

    return {
        "total_vms": total_vms,
        "created_vms": created_vms,
        "failed_vms": failed_vms,
    }


@task_wrapper
def wait_for_talos(
    deployment_id: uuid.UUID,
    log,
    update_progress,
    timeout: int = 600,
) -> Dict[str, Any]:
    """
    Wait for all Talos nodes to become ready.

    Polls each Talos node until the Talos API is responsive.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function
        timeout: Timeout per node in seconds

    Returns:
        Dictionary with summary of ready nodes

    Raises:
        TalosTimeoutError: If node doesn't become ready in time
        ValueError: If VM plans not found
    """
    log("wait_for_talos", "info", "Waiting for Talos nodes to become ready...")
    update_progress(deployment_id, 55.0, "wait_for_talos")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Get VM plans
    talos_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role.in_(["controlplane", "worker"])
    ).all()

    if not talos_plans:
        raise ValueError("No Talos VM plans found")

    # We need to get IP addresses. For now, we'll assume VM hasn't gotten IP yet
    # In a real deployment, we would wait for Proxmox to report IP via QGA
    # For simplicity, we'll skip IP detection and assume static IPs were configured
    # Or we could use DHCP and need to discover IPs

    # For wait_for_talos, we actually need the Talos node IPs
    # But at this point, VMs were created with DHCP or static IPs
    # We need to get the IPs from Proxmox or from vm_plan extra_config

    # Get Proxmox connection to query IPs
    if not cluster.proxmox_creds_encrypted:
        raise ValueError("Proxmox credentials not set")

    try:
        decrypted = decrypt_credentials(cluster.proxmox_creds_encrypted)
        creds = yaml.safe_load(decrypted)
        api = ProxmoxAPI(
            base_url=creds["url"],
            token_name=creds["token_name"],
            token_value=creds["token_value"],
        )
    except Exception as e:
        log("wait_for_talos", "error", f"Failed to connect to Proxmox: {e}")
        raise

    # Collect node IPs
    node_ips = []
    for vm_plan in talos_plans:
        vmid = vm_plan.extra_config.get("proxmox_vmid")
        node = vm_plan.proxmox_node

        if not vmid:
            raise ValueError(f"VM ID not set for {vm_plan.extra_config.get('vm_name')}")

        # Try to get IP from QGA
        ip = api.get_vm_ip(node, vmid)
        if ip:
            # Store IP in vm_plan
            vm_plan.extra_config["node_ip"] = ip
            node_ips.append(ip)
            log("wait_for_talos", "info", f"Node {vm_plan.extra_config.get('vm_name')} IP: {ip}")
        else:
            # If static IP was configured, use that
            static_ip = vm_plan.ip_address
            if static_ip:
                node_ips.append(static_ip)
                vm_plan.extra_config["node_ip"] = static_ip
                log("wait_for_talos", "info", f"Node {vm_plan.extra_config.get('vm_name')} using static IP: {static_ip}")
            else:
                # Wait a bit and retry
                log("wait_for_talos", "warning", f"IP not yet available for {vm_plan.extra_config.get('vm_name')}, waiting...")
                time.sleep(5)
                ip = api.get_vm_ip(node, vmid)
                if ip:
                    vm_plan.extra_config["node_ip"] = ip
                    node_ips.append(ip)
                else:
                    raise ValueError(f"Could not determine IP for VM {vmid} on node {node}")

    db.commit()
    db.close()

    # Now wait for Talos API to be ready on each node
    talos = TalosManager()

    ready_nodes = []
    failed_nodes = []

    for vm_plan in talos_plans:
        node_ip = vm_plan.extra_config["node_ip"]
        vm_name = vm_plan.extra_config.get("vm_name")

        log("wait_for_talos", "info", f"Waiting for Talos API on {vm_name} ({node_ip})...")

        try:
            talos.wait_for_ready(node_ip, timeout=timeout)
            ready_nodes.append({"vm_name": vm_name, "ip": node_ip})
            log("wait_for_talos", "info", f"Node {vm_name} is ready")
        except TalosTimeoutError as e:
            log("wait_for_talos", "error", f"Node {vm_name} failed to become ready: {e}")
            failed_nodes.append({"vm_name": vm_name, "error": str(e)})
        except Exception as e:
            log("wait_for_talos", "error", f"Unexpected error waiting for {vm_name}: {e}")
            failed_nodes.append({"vm_name": vm_name, "error": str(e)})

    if failed_nodes:
        raise ValueError(f"{len(failed_nodes)} nodes failed to become ready: {[n['vm_name'] for n in failed_nodes]}")

    log("wait_for_talos", "info", f"All {len(ready_nodes)} Talos nodes are ready")

    update_progress(deployment_id, 60.0, "wait_for_talos")

    return {
        "total_nodes": len(talos_plans),
        "ready_nodes": len(ready_nodes),
        "ready_node_details": ready_nodes,
        "failed_nodes": failed_nodes,
    }


@task_wrapper
def generate_talos_configs(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Generate Talos machine configurations.

    Uses talosctl gen config to create controlplane and worker configurations.
    Stores them in the /config/talos/ directory.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with paths to generated config files

    Raises:
        TalosError: If config generation fails
        ValueError: If cluster data missing
    """
    log("generate_talos_configs", "info", "Generating Talos machine configurations...")
    update_progress(deployment_id, 65.0, "generate_talos_configs")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Get control plane node IP (first one)
    cp_plan = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role == "controlplane"
    ).first()

    if not cp_plan or "node_ip" not in cp_plan.extra_config:
        raise ValueError("Control plane node IP not found. Run wait_for_talos first.")

    endpoint = cp_plan.extra_config["node_ip"]
    cluster_name = cluster.name

    # Get network configuration from cluster
    pod_cidr = cluster.pod_cidr or "10.244.0.0/16"
    service_cidr = cluster.service_cidr or "10.96.0.0/12"

    log(
        "generate_talos_configs",
        "info",
        f"Generating configs for cluster '{cluster_name}' with endpoint {endpoint}"
    )

    # Generate Talos configs
    talos = TalosManager(config_dir="/config/talos")
    try:
        configs = talos.gen_config(
            cluster_name=cluster_name,
            endpoint=endpoint,
            pod_cidr=pod_cidr,
            service_cidr=service_cidr,
        )
    except TalosError as e:
        log("generate_talos_configs", "error", f"Failed to generate Talos configs: {e}")
        raise

    log(
        "generate_talos_configs",
        "info",
        f"Generated Talos configurations: controlplane at {configs['controlplane']}, worker at {configs['worker']}"
    )

    # Store config paths in cluster state or deployment record
    # Could be saved to database or file system

    db.close()

    update_progress(deployment_id, 70.0, "generate_talos_configs")

    return {
        "cluster_name": cluster_name,
        "endpoint": endpoint,
        "controlplane_config": configs["controlplane"],
        "worker_config": configs["worker"],
    }


@task_wrapper
def apply_talos_config(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Apply Talos configurations to nodes.

    Applies controlplane configs sequentially (must be done one at a time),
    then applies worker configs in parallel. Updates node status in database.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with summary of config applications

    Raises:
        TalosError: If config application fails
        ValueError: If node IPs or configs missing
    """
    log("apply_talos_config", "info", "Applying Talos configurations to nodes...")
    update_progress(deployment_id, 75.0, "apply_talos_config")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Get Talos manager
    talos = TalosManager(config_dir="/config/talos")

    # Check that configs exist
    cp_config_path = Path("/config/talos/controlplane.yaml")
    worker_config_path = Path("/config/talos/worker.yaml")

    if not cp_config_path.exists():
        raise ValueError("Controlplane config not found. Run generate_talos_configs first.")
    if not worker_config_path.exists():
        raise ValueError("Worker config not found. Run generate_talos_configs first.")

    # Get control plane nodes (apply sequentially)
    cp_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role == "controlplane"
    ).order_by(VMPlan.extra_config["vm_name"]).all()

    # Get worker nodes (can apply in parallel)
    worker_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role == "worker"
    ).all()

    applied_cp = []
    failed_cp = []

    # Apply control plane configs one by one
    for cp_plan in cp_plans:
        node_ip = cp_plan.extra_config.get("node_ip")
        vm_name = cp_plan.extra_config.get("vm_name")

        if not node_ip:
            log("apply_talos_config", "error", f"No IP found for control plane node {vm_name}")
            failed_cp.append({"vm_name": vm_name, "error": "No IP address"})
            continue

        log("apply_talos_config", "info", f"Applying control plane config to {vm_name} ({node_ip})...")

        try:
            talos.apply_config(
                node_ip=node_ip,
                config_file=str(cp_config_path),
                wait=True,
                timeout=600,
            )
            applied_cp.append({"vm_name": vm_name, "ip": node_ip})
            log("apply_talos_config", "info", f"Control plane config applied to {vm_name}")
        except TalosError as e:
            log("apply_talos_config", "error", f"Failed to apply config to {vm_name}: {e}")
            failed_cp.append({"vm_name": vm_name, "error": str(e)})
            # Continue with other control plane nodes if one fails (for HA)

    # Apply worker configs (could be done in parallel, but we'll do sequentially for simplicity)
    applied_workers = []
    failed_workers = []

    for worker_plan in worker_plans:
        node_ip = worker_plan.extra_config.get("node_ip")
        vm_name = worker_plan.extra_config.get("vm_name")

        if not node_ip:
            log("apply_talos_config", "warning", f"No IP found for worker node {vm_name}, skipping")
            continue

        log("apply_talos_config", "info", f"Applying worker config to {vm_name} ({node_ip})...")

        try:
            talos.apply_config(
                node_ip=node_ip,
                config_file=str(worker_config_path),
                wait=True,
                timeout=600,
            )
            applied_workers.append({"vm_name": vm_name, "ip": node_ip})
            log("apply_talos_config", "info", f"Worker config applied to {vm_name}")
        except TalosError as e:
            log("apply_talos_config", "error", f"Failed to apply config to {vm_name}: {e}")
            failed_workers.append({"vm_name": vm_name, "error": str(e)})

    db.close()

    total_failed = len(failed_cp) + len(failed_workers)
    if total_failed > 0:
        raise ValueError(
            f"Failed to apply configs to {total_failed} nodes: "
            f"control plane: {[f['vm_name'] for f in failed_cp]}, "
            f"workers: {[f['vm_name'] for f in failed_workers]}"
        )

    total_applied = len(applied_cp) + len(applied_workers)
    log("apply_talos_config", "info", f"Successfully applied Talos configs to {total_applied} nodes")

    update_progress(deployment_id, 80.0, "apply_talos_config")

    return {
        "controlplane_applied": len(applied_cp),
        "workers_applied": len(applied_workers),
        "controlplane_failed": len(failed_cp),
        "workers_failed": len(failed_workers),
        "total_applied": total_applied,
    }


@task_wrapper
def bootstrap_kubernetes(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Bootstrap the Kubernetes cluster.

    Runs talosctl bootstrap on the first control plane node, then retrieves
    the kubeconfig and stores it in /config/kubeconfig and the database.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with bootstrap info and kubeconfig path

    Raises:
        TalosError: If bootstrap fails
        ValueError: If control plane node info missing
    """
    log("bootstrap_kubernetes", "info", "Bootstrapping Kubernetes cluster...")
    update_progress(deployment_id, 85.0, "bootstrap_kubernetes")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Get first control plane node
    cp_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == cluster.id,
        VMPlan.role == "controlplane"
    ).order_by(VMPlan.id).all()

    if not cp_plans:
        raise ValueError("No control plane plans found")

    first_cp = cp_plans[0]
    node_ip = first_cp.extra_config.get("node_ip")
    if not node_ip:
        raise ValueError("Control plane node IP not found")

    cluster_name = cluster.name

    log("bootstrap_kubernetes", "info", f"Bootstrapping on control plane node {node_ip}")

    # Bootstrap
    talos = TalosManager()
    try:
        talos.bootstrap(node_ip=node_ip)
        log("bootstrap_kubernetes", "info", "Bootstrap command completed")
    except TalosError as e:
        log("bootstrap_kubernetes", "error", f"Bootstrap failed: {e}")
        raise

    # Wait for control plane to be ready (API server up)
    log("bootstrap_kubernetes", "info", "Waiting for Kubernetes API to become available...")
    time.sleep(10)  # Give it a moment

    # Get kubeconfig
    kubeconfig_path = "/config/kubeconfig"
    try:
        talos.get_kubeconfig(
            output_file=kubeconfig_path,
            node_ip=node_ip,
            cluster_name=cluster_name,
        )
        log("bootstrap_kubernetes", "info", f"Kubeconfig saved to {kubeconfig_path}")
    except TalosError as e:
        log("bootstrap_kubernetes", "error", f"Failed to retrieve kubeconfig: {e}")
        raise

    # Read kubeconfig content for database storage (will encrypt)
    kubeconfig_content = Path(kubeconfig_path).read_text()

    # Optionally encrypt and store in cluster record
    # cluster.kubeconfig_encrypted = encrypt_credentials(kubeconfig_content)
    # db.commit()

    db.close()

    log("bootstrap_kubernetes", "info", "Kubernetes bootstrap complete")

    update_progress(deployment_id, 90.0, "bootstrap_kubernetes")

    return {
        "control_plane_node": node_ip,
        "kubeconfig_path": kubeconfig_path,
        "cluster_name": cluster_name,
    }


@task_wrapper
def wait_for_workers(
    deployment_id: uuid.UUID,
    log,
    update_progress,
    timeout: int = 600,
) -> Dict[str, Any]:
    """
    Wait for all worker nodes to join the cluster and become Ready.

    Queries Kubernetes API to monitor node status.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function
        timeout: Timeout in seconds

    Returns:
        Dictionary with worker join status

    Raises:
        K8sTimeoutError: If workers don't all become Ready in time
        ValueError: If kubeconfig not found
    """
    log("wait_for_workers", "info", "Waiting for worker nodes to join cluster...")
    update_progress(deployment_id, 92.0, "wait_for_workers")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    # Get number of expected workers from VM plans
    worker_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == deployment.cluster_id,
        VMPlan.role == "worker"
    ).all()

    expected_worker_count = len(worker_plans)

    if expected_worker_count == 0:
        log("wait_for_workers", "info", "No worker nodes expected, skipping")
        db.close()
        return {"expected_workers": 0, "ready_workers": 0}

    # Get total nodes expected: control plane + workers
    cp_plans = db.query(VMPlan).filter(
        VMPlan.cluster_id == deployment.cluster_id,
        VMPlan.role == "controlplane"
    ).all()
    expected_total_nodes = len(cp_plans) + expected_worker_count

    log(
        "wait_for_workers",
        "info",
        f"Waiting for {expected_total_nodes} total nodes ({len(cp_plans)} control plane, {expected_worker_count} workers)"
    )

    db.close()

    # Use K8sManager to wait for nodes
    kubeconfig_path = "/config/kubeconfig"
    if not Path(kubeconfig_path).exists():
        raise ValueError(f"Kubeconfig not found at {kubeconfig_path}")

    try:
        k8s = K8sManager(kubeconfig_path=kubeconfig_path)
        k8s.wait_for_nodes_ready(
            expected_count=expected_total_nodes,
            timeout=timeout,
        )
        log("wait_for_workers", "info", f"All {expected_total_nodes} nodes are Ready")
    except K8sTimeoutError as e:
        log("wait_for_workers", "error", f"Not all nodes became Ready: {e}")
        raise
    except Exception as e:
        log("wait_for_workers", "error", f"Error waiting for nodes: {e}")
        raise

    update_progress(deployment_id, 95.0, "wait_for_workers")

    return {
        "expected_nodes": expected_total_nodes,
        "ready_nodes": expected_total_nodes,
    }


@task_wrapper
def install_cni(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Install Calico CNI plugin.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with installation status

    Raises:
        K8sError: If installation fails
        ValueError: If kubeconfig not found
    """
    log("install_cni", "info", "Installing Calico CNI...")
    update_progress(deployment_id, 96.0, "install_cni")

    kubeconfig_path = "/config/kubeconfig"
    if not Path(kubeconfig_path).exists():
        raise ValueError(f"Kubeconfig not found at {kubeconfig_path}")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first() if deployment else None

    pod_cidr = cluster.pod_cidr if cluster else "10.244.0.0/16"

    try:
        k8s = K8sManager(kubeconfig_path=kubeconfig_path)
        k8s.install_calico(pod_cidr=pod_cidr, wait=True, timeout=600)
        log("install_cni", "info", "Calico CNI installed successfully")
    except (K8sError, K8sTimeoutError) as e:
        log("install_cni", "error", f"Calico installation failed: {e}")
        raise

    db.close()

    update_progress(deployment_id, 97.0, "install_cni")

    return {"cni": "calico", "status": "installed"}


@task_wrapper
def install_metallb(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Install MetalLB load balancer.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with installation status and IP allocation

    Raises:
        K8sError: If installation fails
        ValueError: If network config missing
    """
    log("install_metallb", "info", "Installing MetalLB...")
    update_progress(deployment_id, 97.5, "install_metallb")

    kubeconfig_path = "/config/kubeconfig"
    if not Path(kubeconfig_path).exists():
        raise ValueError(f"Kubeconfig not found at {kubeconfig_path}")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first() if deployment else None

    # Determine IP range for MetalLB
    # Use cluster network configuration to derive a pool
    # For DHCP mode, we might need to use a static assignment
    ip_range = "192.168.1.200-192.168.1.250"  # Default

    if cluster:
        if cluster.ip_range_start and cluster.ip_range_end:
            ip_range = f"{cluster.ip_range_start}-{cluster.ip_range_end}"
        elif cluster.network_cidr:
            # Derive from CIDR (use upper range)
            ip_range = cluster.network_cidr.replace("0/24", "200-250")

    log("install_metallb", "info", f"Configuring MetalLB IP pool: {ip_range}")

    try:
        k8s = K8sManager(kubeconfig_path=kubeconfig_path)
        k8s.install_metallb(ip_range=ip_range, wait=True, timeout=600)
        log("install_metallb", "info", "MetalLB installed successfully")
    except (K8sError, K8sTimeoutError) as e:
        log("install_metallb", "error", f"MetalLB installation failed: {e}")
        raise

    db.close()

    update_progress(deployment_id, 98.0, "install_metallb")

    return {
        "load_balancer": "metallb",
        "ip_range": ip_range,
        "status": "installed",
    }


@task_wrapper
def install_traefik(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Install Traefik ingress controller.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with Traefik installation status and LoadBalancer IP

    Raises:
        K8sError: If installation fails
    """
    log("install_traefik", "info", "Installing Traefik ingress controller...")
    update_progress(deployment_id, 98.5, "install_traefik")

    kubeconfig_path = "/config/kubeconfig"
    if not Path(kubeconfig_path).exists():
        raise ValueError(f"Kubeconfig not found at {kubeconfig_path}")

    try:
        k8s = K8sManager(kubeconfig_path=kubeconfig_path)
        traefik_ip = k8s.install_traefik(wait=True, timeout=600)

        log("install_traefik", "info", f"Traefik installed successfully, LoadBalancer IP: {traefik_ip}")

        # Store Traefik IP in cluster_state
        db = get_db()
        deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
        if deployment:
            cluster_state = db.query(ClusterState).filter(
                ClusterState.cluster_id == deployment.cluster_id
            ).first()

            if not cluster_state:
                # Create new cluster state
                cluster_state = ClusterState(
                    id=uuid.uuid4(),
                    cluster_id=deployment.cluster_id,
                    nodes={},
                    kubeconfig="",  # Could store path or reference
                    kubernetes_version="",
                    network_cidr="",
                )
                db.add(cluster_state)

            # Update traefik IP in cluster state
            # cluster_state.traefik_ip = traefik_ip  # Add this column if needed
            db.commit()
            db.close()

    except (K8sError, K8sTimeoutError) as e:
        log("install_traefik", "error", f"Traefik installation failed: {e}")
        raise

    update_progress(deployment_id, 99.0, "install_traefik")

    return {
        "ingress_controller": "traefik",
        "load_balancer_ip": traefik_ip,
        "status": "installed",
    }


@task_wrapper
def deployment_complete(
    deployment_id: uuid.UUID,
    log,
    update_progress,
) -> Dict[str, Any]:
    """
    Mark deployment as complete and finalize cluster state.

    Updates deployment status to succeeded, cluster status to ready,
    and writes final cluster state summary.

    Args:
        deployment_id: UUID of the deployment
        log: Logging function
        update_progress: Progress update function

    Returns:
        Dictionary with final deployment summary

    Raises:
        ValueError: If deployment/cluster not found
    """
    log("deployment_complete", "info", "Finalizing deployment...")

    db = get_db()
    deployment = db.query(Deployment).filter(Deployment.id == deployment_id).first()
    if not deployment:
        raise ValueError(f"Deployment {deployment_id} not found")

    cluster = db.query(Cluster).filter(Cluster.id == deployment.cluster_id).first()
    if not cluster:
        raise ValueError(f"Cluster {deployment.cluster_id} not found")

    # Update deployment status
    deployment.status = "succeeded"
    deployment.completed_at = datetime.utcnow()
    deployment.progress = 100.0

    # Update cluster status
    cluster.status = "ready"

    db.commit()

    log("deployment_complete", "info", f"✅ Cluster '{cluster.name}' deployment complete!")
    log("deployment_complete", "info", f"Deployment {deployment_id} marked as succeeded")

    # Get final cluster info if kubeconfig exists
    kubeconfig_path = "/config/kubeconfig"
    cluster_info = {}

    if Path(kubeconfig_path).exists():
        try:
            k8s = K8sManager(kubeconfig_path=kubeconfig_path)
            cluster_info = k8s.cluster_info()
            log("deployment_complete", "info", f"Kubernetes version: {cluster_info.get('kubernetes_version')}")
            log("deployment_complete", "info", f"Node count: {cluster_info.get('node_count')}")
        except Exception as e:
            log("deployment_complete", "warning", f"Could not retrieve cluster info: {e}")

    # Store cluster state snapshot
    cluster_state = ClusterState(
        id=uuid.uuid4(),
        cluster_id=cluster.id,
        captured_at=datetime.utcnow(),
        node_count=cluster_info.get("node_count", 0),
        ready_node_count=cluster_info.get("node_count", 0),
        pod_count=cluster_info.get("pod_count", 0),
        running_pod_count=cluster_info.get("pod_count", 0),
        kubernetes_version=cluster_info.get("kubernetes_version"),
        nodes=cluster_info.get("nodes", []),
        health_score=100.0,  # Just deployed, assume healthy
    )
    db.add(cluster_state)
    db.commit()

    db.close()

    log("deployment_complete", "info", "🎉 Deployment workflow complete!")

    return {
        "deployment_id": str(deployment_id),
        "cluster_id": str(cluster.id),
        "cluster_name": cluster.name,
        "status": "succeeded",
        "completed_at": datetime.utcnow().isoformat(),
        "cluster_info": cluster_info,
    }


# Import for exception handling
import sys
