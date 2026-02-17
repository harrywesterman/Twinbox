"""
Wizard configuration data model.

Uses Pydantic for validation and data passing between wizard screens.
"""

from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field, field_validator


class WizardData(BaseModel):
    """Wizard configuration data that flows through all screens."""

    # Cluster basic info
    cluster_name: str = Field(default="", description="Cluster name")

    # SSH credentials
    ssh_public_key: str = Field(default="", description="SSH public key for manager VM")

    # Proxmox credentials (required for preflight checks)
    proxmox_url: str = Field(default="", description="Proxmox API endpoint URL")
    proxmox_token_name: str = Field(default="", description="Proxmox API token name")
    proxmox_token_value: str = Field(default="", description="Proxmox API token secret")
    proxmox_verify_ssl: bool = Field(default=False, description="Verify Proxmox SSL certificates")

    # Management VM configuration
    vm_cpu_cores: int = Field(default=2, ge=1, le=16, description="VM CPU cores")
    vm_ram_mb: int = Field(default=4096, ge=512, le=131072, description="VM RAM in MB")
    vm_disk_gb: int = Field(default=32, ge=8, le=1024, description="VM disk size in GB")
    vm_bridge: str = Field(default="vmbr0", description="Network bridge")
    vm_storage: str = Field(default="local-lvm", description="Storage pool")

    # Cluster topology
    control_plane_count: int = Field(default=3, ge=1, le=5, description="Number of control plane nodes")
    worker_count: int = Field(default=0, ge=0, description="Number of worker nodes")
    selected_nodes: List[str] = Field(default_factory=list, description="Selected Proxmox node names")

    # Wizard tracking
    wizard_started_at: datetime = Field(default_factory=datetime.utcnow)
    preflight_passed: bool = Field(default=False)

    @field_validator("cluster_name")
    @classmethod
    def validate_cluster_name(cls, v: str) -> str:
        """Validate cluster name is alphanumeric with hyphens."""
        import re
        # Allow empty string during initial wizard setup
        if v and not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9\-]*$", v):
            raise ValueError("Cluster name must start with letter/number and contain only letters, numbers, and hyphens")
        return v.lower()

    @field_validator("selected_nodes")
    @classmethod
    def validate_selected_nodes(cls, v: List[str]) -> List[str]:
        """Validate node selection - allow empty during wizard, enforce at submission."""
        # Allow empty list during initial wizard setup
        return v

    def to_dict(self) -> dict:
        """Convert to plain dictionary."""
        return self.model_dump()

    @classmethod
    def from_dict(cls, data: dict) -> "WizardData":
        """Create WizardData from dictionary."""
        return cls(**data)
