"""
Pydantic schemas for Twinbox API.

Define request/response models with proper validation, examples, and Field descriptions.
"""

from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, Field, field_validator, ConfigDict
from ipaddress import IPv4Address, IPv4Network


# ========== Cluster Schemas ==========

class ClusterCreate(BaseModel):
    """
    Schema for creating a new cluster.

    Attributes:
        name: Cluster name (unique, required)
        description: Optional cluster description
        proxmox_host: Proxmox server hostname/IP
        proxmox_user: Proxmox API username
        proxmox_password: Proxmox API password (will be encrypted)
        proxmox_ssh_key: Optional SSH key for management VM provisioning
        network_bridge: Proxmox network bridge interface (default: vmbr0)
        network_cidr: Network CIDR for VM IP allocation (e.g., "192.168.1.0/24")
        network_gateway: Default gateway IP address
        ip_range_start: Start IP for static allocation (optional)
        ip_range_end: End IP for static allocation (optional)
        dhcp_mode: If true, VMs use DHCP; if false, use static IPs (default: true)
        talos_version: Talos version to install (optional)
        kubernetes_version: Kubernetes version to install (optional)
    """
    model_config = ConfigDict(from_attributes=True)

    name: str = Field(
        ...,
        min_length=1,
        max_length=255,
        description="Cluster name",
        examples=["production-cluster", "dev-cluster"]
    )
    description: Optional[str] = Field(
        None,
        max_length=1000,
        description="Optional cluster description"
    )
    proxmox_host: str = Field(
        ...,
        description="Proxmox server hostname or IP address",
        examples=["proxmox.example.com", "192.168.1.100"]
    )
    proxmox_user: str = Field(
        ...,
        description="Proxmox API username (e.g., 'root@pam')",
        examples=["root@pam", "admin@pve"]
    )
    proxmox_password: str = Field(
        ...,
        description="Proxmox API password (will be encrypted)",
        examples=["securepassword123"]
    )
    proxmox_ssh_key: Optional[str] = Field(
        None,
        description="SSH private key for management VM provisioning"
    )
    network_bridge: str = Field(
        "vmbr0",
        description="Proxmox network bridge interface",
        examples=["vmbr0", "vmbr1"]
    )
    network_cidr: str = Field(
        ...,
        description="Network CIDR for VM IP allocation",
        examples=["192.168.1.0/24", "10.0.0.0/16"]
    )
    network_gateway: Optional[str] = Field(
        None,
        description="Default gateway IP address",
        examples=["192.168.1.1", "10.0.0.1"]
    )
    ip_range_start: Optional[str] = Field(
        None,
        description="Start IP for static allocation",
        examples=["192.168.1.100", "10.0.0.100"]
    )
    ip_range_end: Optional[str] = Field(
        None,
        description="End IP for static allocation",
        examples=["192.168.1.200", "10.0.0.200"]
    )
    dhcp_mode: bool = Field(
        True,
        description="If true, VMs use DHCP; if false, use static IPs"
    )
    talos_version: Optional[str] = Field(
        None,
        description="Talos Linux version to install",
        examples=["v1.6.0", "v1.5.5"]
    )
    kubernetes_version: Optional[str] = Field(
        None,
        description="Kubernetes version to install",
        examples=["v1.28.0", "v1.27.4"]
    )

    @field_validator('network_cidr')
    @classmethod
    def validate_cidr(cls, v: str) -> str:
        """Validate CIDR notation."""
        try:
            IPv4Network(v, strict=False)
        except ValueError:
            raise ValueError("Invalid CIDR notation")
        return v

    @field_validator('network_gateway')
    @classmethod
    def validate_gateway(cls, v: Optional[str], info) -> Optional[str]:
        """Validate gateway IP if provided."""
        if v is not None:
            try:
                IPv4Address(v)
            except ValueError:
                raise ValueError("Invalid gateway IP address")
        return v

    @field_validator('ip_range_start', 'ip_range_end')
    @classmethod
    def validate_ip(cls, v: Optional[str], info) -> Optional[str]:
        """Validate IP address if provided."""
        if v is not None:
            try:
                IPv4Address(v)
            except ValueError:
                raise ValueError(f"Invalid IP address: {v}")
        return v


class ClusterResponse(BaseModel):
    """
    Schema for cluster response.

    Attributes:
        id: Cluster UUID
        name: Cluster name
        description: Optional cluster description
        status: Current status (pending, provisioning, ready, error, deleting)
        talos_version: Talos version
        kubernetes_version: Kubernetes version
        pod_cidr: Pod network CIDR
        service_cidr: Service network CIDR
        endpoint: Cluster API endpoint
        created_at: Creation timestamp
        updated_at: Last update timestamp
    """
    model_config = ConfigDict(from_attributes=True)

    id: str = Field(..., description="Cluster UUID", examples=["550e8400-e29b-41d4-a716-446655440000"])
    name: str = Field(..., description="Cluster name")
    description: Optional[str] = Field(None, description="Cluster description")
    status: str = Field(..., description="Cluster status", examples=["pending", "provisioning", "ready", "error"])
    talos_version: Optional[str] = Field(None, description="Talos version")
    kubernetes_version: Optional[str] = Field(None, description="Kubernetes version")
    pod_cidr: str = Field(..., description="Pod CIDR", examples=["10.244.0.0/16"])
    service_cidr: str = Field(..., description="Service CIDR", examples=["10.96.0.0/12"])
    endpoint: Optional[str] = Field(None, description="Cluster API endpoint")
    created_at: datetime = Field(..., description="Creation timestamp")
    updated_at: datetime = Field(..., description="Last update timestamp")


class VMPlan(BaseModel):
    """
    Schema for VM plan/specification.

    Attributes:
        vm_name: VM hostname
        role: VM role (management, controlplane, worker)
        target_node: Proxmox node to deploy on
        cpu: CPU cores
        ram_mb: RAM in MB
        disk_gb: Disk size in GB
        ip_address: IP address (if static mode)
        bridge: Network bridge
        mac_address: Optional MAC address
        iso: ISO/image to use for installation
    """
    model_config = ConfigDict(from_attributes=True)

    vm_name: str = Field(..., description="VM hostname")
    role: str = Field(..., description="VM role", examples=["management", "controlplane", "worker"])
    target_node: str = Field(..., description="Proxmox node name")
    cpu: int = Field(..., gt=0, description="Number of CPU cores")
    ram_mb: int = Field(..., gt=0, description="RAM in megabytes")
    disk_gb: int = Field(..., gt=0, description="Disk size in gigabytes")
    ip_address: Optional[str] = Field(None, description="IP address (static mode)")
    bridge: str = Field(..., description="Network bridge interface")
    mac_address: Optional[str] = Field(None, description="MAC address")
    iso: str = Field(..., description="Installation ISO or template")


class ResourceSummary(BaseModel):
    """
    Schema for resource summary.

    Attributes:
        total_cpu_needed: Total CPU cores needed
        total_ram_needed: Total RAM needed in MB
        total_disk_needed: Total disk needed in GB
        total_cpu_available: Total CPU available
        total_ram_available: Total RAM available in MB
        total_disk_available: Total disk available in GB
        remaining_cpu: Remaining CPU after deployment
        remaining_ram_mb: Remaining RAM in MB
        remaining_disk_gb: Remaining disk in GB
        num_controlplane: Number of control plane nodes
        num_workers: Number of worker nodes
    """
    model_config = ConfigDict(from_attributes=True)

    total_cpu_needed: float = Field(..., description="Total CPU cores needed")
    total_ram_needed: int = Field(..., description="Total RAM needed in MB")
    total_disk_needed: int = Field(..., description="Total disk needed in GB")
    total_cpu_available: float = Field(..., description="Total CPU available")
    total_ram_available: int = Field(..., description="Total RAM available in MB")
    total_disk_available: int = Field(..., description="Total disk available in GB")
    remaining_cpu: float = Field(..., description="Remaining CPU")
    remaining_ram_mb: int = Field(..., description="Remaining RAM in MB")
    remaining_disk_gb: int = Field(..., description="Remaining disk in GB")
    num_controlplane: int = Field(..., description="Number of control plane nodes")
    num_workers: int = Field(..., description="Number of worker nodes")


class DeploymentStatus(BaseModel):
    """
    Schema for deployment status.

    Attributes:
        deployment_id: Deployment UUID
        cluster_id: Cluster UUID
        status: Deployment status (pending, running, success, failed, cancelled)
        deployment_type: Type of deployment (create, update, delete)
        progress: Completion percentage (0-100)
        current_step: Current step in deployment workflow
        error_message: Error message if failed
        started_at: Deployment start timestamp
        completed_at: Deployment completion timestamp (if done)
    """
    model_config = ConfigDict(from_attributes=True)

    deployment_id: str = Field(..., description="Deployment UUID")
    cluster_id: str = Field(..., description="Cluster UUID")
    status: str = Field(..., description="Deployment status", examples=["pending", "running", "success", "failed", "cancelled"])
    deployment_type: str = Field(..., description="Deployment type", examples=["create", "update", "delete"])
    progress: float = Field(..., ge=0, le=100, description="Progress percentage")
    current_step: Optional[str] = Field(None, description="Current deployment step")
    error_message: Optional[str] = Field(None, description="Error message if deployment failed")
    started_at: datetime = Field(..., description="Start timestamp")
    completed_at: Optional[datetime] = Field(None, description="Completion timestamp")


class LogEntry(BaseModel):
    """
    Schema for deployment log entry.

    Attributes:
        id: Log entry UUID
        deployment_id: Deployment UUID
        level: Log level (DEBUG, INFO, WARNING, ERROR)
        message: Log message
        context: Additional structured context data
        timestamp: Log entry timestamp
    """
    model_config = ConfigDict(from_attributes=True)

    id: str = Field(..., description="Log entry UUID")
    deployment_id: str = Field(..., description="Deployment UUID")
    level: str = Field(..., description="Log level", examples=["DEBUG", "INFO", "WARNING", "ERROR"])
    message: str = Field(..., description="Log message")
    context: Optional[dict] = Field(None, description="Additional context data")
    timestamp: datetime = Field(..., description="Log timestamp")


class ReviewPlan(BaseModel):
    """
    Schema for deployment review plan.

    This is the complete plan shown to the user before starting deployment,
    including VM specifications, placement, and resource summary.

    Attributes:
        cluster_id: Cluster UUID
        cluster_name: Cluster name
        vm_plan: List of VM specifications
        network: Network configuration summary
        resources: Resource allocation summary
        estimated_duration: Estimated deployment duration in seconds
    """
    model_config = ConfigDict(from_attributes=True)

    cluster_id: str = Field(..., description="Cluster UUID")
    cluster_name: str = Field(..., description="Cluster name")
    vm_plan: List[VMPlan] = Field(..., description="List of VM deployment plans")
    network: dict = Field(..., description="Network configuration")
    resources: ResourceSummary = Field(..., description="Resource summary")
    estimated_duration: Optional[int] = Field(None, ge=0, description="Estimated deployment duration in seconds")


class DeployRequest(BaseModel):
    """
    Schema for deployment start request.

    Attributes:
        confirm: Must be true to confirm deployment
    """
    model_config = ConfigDict(from_attributes=True)

    confirm: bool = Field(..., description="Must be true to confirm deployment")


# ========== Error Schemas ==========

class ErrorResponse(BaseModel):
    """Schema for error responses."""
    model_config = ConfigDict(from_attributes=True)

    error: str = Field(..., description="Error type")
    message: str = Field(..., description="Error message")
    details: Optional[dict] = Field(None, description="Additional error details")
