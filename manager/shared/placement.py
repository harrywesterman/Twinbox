"""
Placement engine for Twinbox.

This module provides algorithms for discovering cluster topology, calculating
VM resource requirements, distributing VMs across physical nodes, allocating
IP addresses, and validating resource availability.

The placement strategy:
- Management VM gets fixed resources (2 CPU, 4GB RAM, 32GB disk) and is placed
  on the least-loaded node.
- Control plane VMs get fixed resources (2 CPU, 4GB RAM each) and are spread
  across distinct physical hosts for high availability.
- Worker VMs share the remaining resources and are distributed to balance load.

All functions are pure (no side effects) and fully type-hinted.
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple
import ipaddress
from itertools import cycle


@dataclass
class NodeInfo:
    """Information about a Proxmox node."""
    id: str
    total_cpu: float  # Total CPU cores
    total_ram_mb: int  # Total RAM in MB
    total_disk_gb: int  # Total disk in GB
    used_cpu: float = 0.0  # Already used CPU cores
    used_ram_mb: int = 0  # Already used RAM in MB
    used_disk_gb: int = 0  # Already used disk in GB

    @property
    def available_cpu(self) -> float:
        """Available CPU cores."""
        return max(0.0, self.total_cpu - self.used_cpu)

    @property
    def available_ram_mb(self) -> int:
        """Available RAM in MB."""
        return max(0, self.total_ram_mb - self.used_ram_mb)

    @property
    def available_disk_gb(self) -> int:
        """Available disk in GB."""
        return max(0, self.total_disk_gb - self.used_disk_gb)

    @property
    def utilization(self) -> float:
        """Overall utilization as a fraction (0-1)."""
        cpu_util = self.used_cpu / self.total_cpu if self.total_cpu > 0 else 0
        ram_util = self.used_ram_mb / self.total_ram_mb if self.total_ram_mb > 0 else 0
        disk_util = self.used_disk_gb / self.total_disk_gb if self.total_disk_gb > 0 else 0
        return (cpu_util + ram_util + disk_util) / 3


@dataclass
class NetworkInfo:
    """Network configuration for VM deployment."""
    bridge: str
    cidr: str  # e.g., "192.168.1.0/24"
    gateway: Optional[str] = None
    ip_range_start: Optional[str] = None  # For static allocation
    ip_range_end: Optional[str] = None
    dhcp_mode: bool = True

    @property
    def network(self) -> ipaddress.IPv4Network:
        """Return IPv4Network object for CIDR."""
        return ipaddress.IPv4Network(self.cidr, strict=False)


@dataclass
class VMPlan:
    """Complete specification for deploying a single VM."""
    vm_name: str
    role: str  # "management", "controlplane", "worker"
    target_node: str
    cpu: int
    ram_mb: int
    disk_gb: int
    ip_address: Optional[str] = None
    bridge: str = "vmbr0"
    mac_address: Optional[str] = None
    iso: str = "local:iso/talos-amd64.iso"  # Default for Talos VMs

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "vm_name": self.vm_name,
            "role": self.role,
            "target_node": self.target_node,
            "cpu": self.cpu,
            "ram_mb": self.ram_mb,
            "disk_gb": self.disk_gb,
            "ip_address": self.ip_address,
            "bridge": self.bridge,
            "mac_address": self.mac_address,
            "iso": self.iso,
        }


@dataclass
class ClusterConfig:
    """Configuration for the cluster deployment."""
    num_controlplane: int = 3
    num_workers: int = 0
    network_bridge: str = "vmbr0"
    network_cidr: Optional[str] = None
    network_gateway: Optional[str] = None
    ip_range_start: Optional[str] = None
    ip_range_end: Optional[str] = None
    dhcp_mode: bool = True

    # Resource overrides (optional, defaults are used if not specified)
    management_cpu: int = 2
    management_ram_mb: int = 4096
    management_disk_gb: int = 32
    controlplane_cpu: int = 2
    controlplane_ram_mb: int = 4096
    controlplane_disk_gb: int = 50
    worker_cpu: int = 2
    worker_ram_mb: int = 4096
    worker_disk_gb: int = 50

    def validate(self) -> None:
        """Validate configuration values."""
        if self.num_controlplane < 1 or self.num_controlplane % 2 == 0:
            raise ValueError("num_controlplane must be odd and >= 1 (recommended: 1, 3, 5)")
        if self.num_controlplane > 5:
            raise ValueError("num_controlplane cannot exceed 5")
        if self.num_workers < 0:
            raise ValueError("num_workers cannot be negative")

        # Check IP range if static mode
        if not self.dhcp_mode:
            if not all([self.network_cidr, self.ip_range_start, self.ip_range_end]):
                raise ValueError(
                    "Static mode requires network_cidr, ip_range_start, and ip_range_end"
                )

            # Validate that IP range is within CIDR
            try:
                network = ipaddress.IPv4Network(self.network_cidr, strict=False)
                start = ipaddress.IPv4Address(self.ip_range_start)
                end = ipaddress.IPv4Address(self.ip_range_end)
                if start not in network or end not in network:
                    raise ValueError("IP range must be within network CIDR")
                if start >= end:
                    raise ValueError("ip_range_start must be less than ip_range_end")
            except ValueError as e:
                raise ValueError(f"Invalid IP configuration: {e}")


@dataclass
class ClusterTopology:
    """Discovered cluster topology."""
    nodes: List[NodeInfo]
    networks: List[Dict[str, Any]]  # Raw network bridge data from Proxmox
    available_nodes: List[NodeInfo]  # Nodes filtered by online status


def discover_cluster_topology(proxmox_api: Any) -> ClusterTopology:
    """
    Discover the physical cluster topology from Proxmox.

    Queries the Proxmox API to gather information about all nodes,
    their resource capacity and current utilization, and available
    network bridges.

    Args:
        proxmox_api: An authenticated ProxmoxAPI instance

    Returns:
        ClusterTopology object with nodes, networks, and filtered available nodes

    Raises:
        ProxmoxAPIError: If discovery fails
    """
    # Get all nodes
    raw_nodes = proxmox_api.list_nodes()

    nodes = []
    available_nodes = []

    for raw_node in raw_nodes:
        if raw_node.get("status") != "online":
            continue

        node_id = raw_node["id"]

        # Get node status (has CPU, memory, disk info)
        try:
            status = proxmox_api.get_node_resources(node_id)
        except Exception:
            # Skip nodes we can't query
            continue

        # Parse CPU info
        cpu_info = status.get("cpu", {})
        total_cpu = float(cpu_info.get("cores", 0))
        # CPU usage is a fraction; convert to cores
        used_cpu = total_cpu * float(cpu_info.get("usage", 0))

        # Parse memory info
        mem_info = status.get("memory", {})
        total_ram_mb = int(mem_info.get("total", 0) // (1024 * 1024))  # bytes to MB
        used_ram_mb = int(mem_info.get("used", 0) // (1024 * 1024))

        # Parse disk info
        disk_info = status.get("rootfs", {})
        total_disk_gb = int(disk_info.get("total", 0) // (1024 * 1024 * 1024))  # bytes to GB
        used_disk_gb = int(disk_info.get("used", 0) // (1024 * 1024 * 1024))

        node = NodeInfo(
            id=node_id,
            total_cpu=total_cpu,
            total_ram_mb=total_ram_mb,
            total_disk_gb=total_disk_gb,
            used_cpu=used_cpu,
            used_ram_mb=used_ram_mb,
            used_disk_gb=used_disk_gb,
        )
        nodes.append(node)
        available_nodes.append(node)

    # Get network bridges
    raw_bridges = []
    for node in available_nodes:
        try:
            bridges = proxmox_api.list_networks(node.id)
            raw_bridges.extend(bridges)
        except Exception:
            continue

    return ClusterTopology(
        nodes=nodes,
        networks=raw_bridges,
        available_nodes=available_nodes,
    )


def calculate_resource_requirements(
    total_available: Dict[str, Any],
    num_controlplane: int,
    num_workers: int,
    config: ClusterConfig,
) -> Dict[str, Any]:
    """
    Calculate resource requirements for all VMs.

    Based on the total available cluster resources and desired node counts,
    compute the resource allocation for management, control plane, and worker VMs.

    The algorithm:
    - Management VM: Fixed resources (config.management_*)
    - Each control plane VM: Fixed resources (config.controlplane_*)
    - Each worker VM: Fixed resources (config.worker_*) or divide remaining equally

    Args:
        total_available: Dict with keys: total_cpu, total_ram_mb, total_disk_gb
        num_controlplane: Number of control plane nodes (typically 1, 3, or 5)
        num_workers: Number of worker nodes
        config: ClusterConfig with resource specs and tolerances

    Returns:
        Dictionary with keys:
        - management: {cpu, ram_mb, disk_gb}
        - controlplane: {cpu, ram_mb, disk_gb}
        - worker: {cpu, ram_mb, disk_gb}
        - summary: dict with totals and remaining resources
    """
    # Fixed specs
    management_spec = {
        "cpu": config.management_cpu,
        "ram_mb": config.management_ram_mb,
        "disk_gb": config.management_disk_gb,
    }

    controlplane_spec = {
        "cpu": config.controlplane_cpu,
        "ram_mb": config.controlplane_ram_mb,
        "disk_gb": config.controlplane_disk_gb,
    }

    worker_spec = {
        "cpu": config.worker_cpu,
        "ram_mb": config.worker_ram_mb,
        "disk_gb": config.worker_disk_gb,
    }

    # Calculate totals needed
    total_cpu_needed = (
        management_spec["cpu"]
        + (num_controlplane * controlplane_spec["cpu"])
        + (num_workers * worker_spec["cpu"])
    )
    total_ram_needed = (
        management_spec["ram_mb"]
        + (num_controlplane * controlplane_spec["ram_mb"])
        + (num_workers * worker_spec["ram_mb"])
    )
    total_disk_needed = (
        management_spec["disk_gb"]
        + (num_controlplane * controlplane_spec["disk_gb"])
        + (num_workers * worker_spec["disk_gb"])
    )

    # Check if we have enough resources
    if total_cpu_needed > total_available["total_cpu"]:
        raise ValueError(
            f"Insufficient CPU: need {total_cpu_needed}, available {total_available['total_cpu']}"
        )
    if total_ram_needed > total_available["total_ram_mb"]:
        raise ValueError(
            f"Insufficient RAM: need {total_ram_needed}MB, available {total_available['total_ram_mb']}MB"
        )
    if total_disk_needed > total_available["total_disk_gb"]:
        raise ValueError(
            f"Insufficient disk: need {total_disk_needed}GB, available {total_available['total_disk_gb']}GB"
        )

    summary = {
        "total_cpu_needed": total_cpu_needed,
        "total_ram_needed": total_ram_needed,
        "total_disk_needed": total_disk_needed,
        "total_cpu_available": total_available["total_cpu"],
        "total_ram_available": total_available["total_ram_mb"],
        "total_disk_available": total_available["total_disk_gb"],
        "remaining_cpu": total_available["total_cpu"] - total_cpu_needed,
        "remaining_ram_mb": total_available["total_ram_mb"] - total_ram_needed,
        "remaining_disk_gb": total_available["total_disk_gb"] - total_disk_needed,
        "num_controlplane": num_controlplane,
        "num_workers": num_workers,
    }

    return {
        "management": management_spec,
        "controlplane": controlplane_spec,
        "worker": worker_spec,
        "summary": summary,
    }


def distribute_vms_across_nodes(
    nodes: List[NodeInfo],
    vm_plans: List[VMPlan],
    control_plane_roles: Optional[List[str]] = None,
) -> Dict[str, str]:
    """
    Distribute VM plans across physical nodes with control plane HA constraint.

    Assigns each VM to a target node such that:
    - Control plane VMs (if any) are placed on distinct physical hosts
    - VMs are distributed to balance overall utilization
    - Node resource capacities are respected (checked by validate_resources separately)

    Args:
        nodes: List of available NodeInfo objects
        vm_plans: List of VMPlan objects (without target_node set)
        control_plane_roles: List of VM names that are control plane (for spreading).
            If None, derived from role field.

    Returns:
        Dictionary mapping vm_name -> target_node_id

    Raises:
        ValueError: If not enough distinct nodes for control plane distribution
    """
    if not nodes:
        raise ValueError("No available nodes for placement")

    # Sort nodes by utilization (least utilized first) for better load balancing
    sorted_nodes = sorted(nodes, key=lambda n: n.utilization)

    assignment: Dict[str, str] = {}

    # First, separate VMs by role
    management_vms = [vm for vm in vm_plans if vm.role == "management"]
    controlplane_vms = [vm for vm in vm_plans if vm.role == "controlplane"]
    worker_vms = [vm for vm in vm_plans if vm.role == "worker"]

    # Control plane must be on distinct nodes
    cp_node_count_needed = len(controlplane_vms)
    if cp_node_count_needed > len(nodes):
        raise ValueError(
            f"Not enough nodes for control plane spread: need {cp_node_count_needed} "
            f"distinct nodes but only {len(nodes)} available"
        )

    # Select distinct nodes for control plane (use least utilized ones)
    cp_assigned_nodes = [node.id for node in sorted_nodes[:cp_node_count_needed]]

    # Assign control plane VMs to distinct nodes (round-robin across selected nodes)
    cp_node_cycle = cycle(cp_assigned_nodes)
    for vm in controlplane_vms:
        assignment[vm.vm_name] = next(cp_node_cycle)

    # Assign management VM (to least utilized node that isn't already hosting a control plane)
    for vm in management_vms:
        # Find least utilized node that hasn't been assigned a control plane yet
        # Prefer nodes without control plane for management isolation, but don't require it
        for node in sorted_nodes:
            if node.id not in assignment.values():
                assignment[vm.vm_name] = node.id
                break
        else:
            # All nodes have control plane; assign to least utilized
            assignment[vm.vm_name] = sorted_nodes[0].id

    # Assign worker VMs to balance load
    # Use round-robin across all nodes, weighted by available resources
    for i, vm in enumerate(worker_vms):
        # Simple round-robin using sorted nodes
        node_idx = i % len(sorted_nodes)
        node = sorted_nodes[node_idx]

        # But try to balance - if this node already has many assignments, try another
        vm_count_on_node = sum(1 for n in assignment.values() if n == node.id)
        if vm_count_on_node >= 2:  # Don't overload one node
            # Find least loaded node
            node_loads = {node.id: 0 for node in sorted_nodes}
            for assigned_node in assignment.values():
                node_loads[assigned_node] = node_loads.get(assigned_node, 0) + 1
            least_loaded = min(sorted_nodes, key=lambda n: node_loads.get(n.id, 0))
            assignment[vm.vm_name] = least_loaded.id
        else:
            assignment[vm.vm_name] = node.id

    return assignment


def allocate_ips(
    network_cidr: str,
    bridge: str,
    mode: str,
    count: int,
    start_ip: Optional[str] = None,
    end_ip: Optional[str] = None,
    reserved: Optional[List[str]] = None,
) -> List[str]:
    """
    Allocate IP addresses for VMs.

    In DHCP mode, returns empty list (DHCP will assign).
    In static mode, allocates sequential IPs from the specified range.

    Args:
        network_cidr: Network CIDR (e.g., "192.168.1.0/24")
        bridge: Bridge interface name (unused, for context)
        mode: "dhcp" or "static"
        count: Number of IPs to allocate
        start_ip: Starting IP for static mode (required if mode="static")
        end_ip: Ending IP for static mode (required if mode="static")
        reserved: List of IPs to skip (e.g., gateway, existing VMs)

    Returns:
        List of allocated IP addresses

    Raises:
        ValueError: If insufficient IPs available in range or invalid configuration
    """
    if mode.lower() == "dhcp":
        return []  # DHCP handles assignment

    if not all([start_ip, end_ip]):
        raise ValueError("Static mode requires start_ip and end_ip")

    try:
        network = ipaddress.IPv4Network(network_cidr, strict=False)
        start = ipaddress.IPv4Address(start_ip)
        end = ipaddress.IPv4Address(end_ip)
    except ValueError as e:
        raise ValueError(f"Invalid IP address or network: {e}")

    if start not in network or end not in network:
        raise ValueError("IP range must be within network CIDR")

    if start >= end:
        raise ValueError("start_ip must be less than end_ip")

    # Generate all IPs in range (inclusive)
    all_ips = [str(ipaddress.IPv4Address(ip_int))
               for ip_int in range(int(start), int(end) + 1)]

    # Remove reserved IPs
    reserved_set = set(reserved or [])
    available_ips = [ip for ip in all_ips if ip not in reserved_set]

    if len(available_ips) < count:
        raise ValueError(
            f"Insufficient IP addresses: need {count}, available {len(available_ips)}"
        )

    # Allocate sequential IPs
    return available_ips[:count]


def generate_vm_plan(
    cluster_config: ClusterConfig,
    topology: ClusterTopology,
    management_node: Optional[str] = None,
    management_vm_name: str = "twinbox-mgmt",
) -> List[VMPlan]:
    """
    Generate complete VM deployment plan based on cluster configuration and topology.

    This function orchestrates:
    - Resource calculation
    - Node assignment (distribution)
    - IP allocation (if static)
    - VMPlan creation for all VM roles

    Args:
        cluster_config: ClusterConfig with desired cluster size and network settings
        topology: ClusterTopology with discovered node resources
        management_node: Optional specific node to place management VM on
            (default: auto-select based on load)
        management_vm_name: Base name for management VM

    Returns:
        List of VMPlan objects with complete specifications for deployment

    Raises:
        ValueError: If configuration invalid or resources insufficient
    """
    cluster_config.validate()

    # Summarize total available resources across all available nodes
    total_cpu = sum(node.available_cpu for node in topology.available_nodes)
    total_ram_mb = sum(node.available_ram_mb for node in topology.available_nodes)
    total_disk_gb = sum(node.available_disk_gb for node in topology.available_nodes)

    # Build total_available dict
    total_available = {
        "total_cpu": total_cpu,
        "total_ram_mb": total_ram_mb,
        "total_disk_gb": total_disk_gb,
    }

    # Calculate resource specs
    reqs = calculate_resource_requirements(
        total_available=total_available,
        num_controlplane=cluster_config.num_controlplane,
        num_workers=cluster_config.num_workers,
        config=cluster_config,
    )

    # Build initial VM plan objects (without node assignment or IPs yet)
    vm_plans: List[VMPlan] = []

    # Add management VM
    mgmt_vm_name = f"{management_vm_name}-1"
    mgmt_plan = VMPlan(
        vm_name=mgmt_vm_name,
        role="management",
        target_node="",  # to be assigned
        cpu=reqs["management"]["cpu"],
        ram_mb=reqs["management"]["ram_mb"],
        disk_gb=reqs["management"]["disk_gb"],
        bridge=cluster_config.network_bridge,
        # Management VM is Ubuntu, not Talos
        iso="local:iso/ubuntu-22.04.iso",
    )
    vm_plans.append(mgmt_plan)

    # Add control plane VMs
    for i in range(1, cluster_config.num_controlplane + 1):
        cp_vm_name = f"talos-cp-{i}"
        cp_plan = VMPlan(
            vm_name=cp_vm_name,
            role="controlplane",
            target_node="",
            cpu=reqs["controlplane"]["cpu"],
            ram_mb=reqs["controlplane"]["ram_mb"],
            disk_gb=reqs["controlplane"]["disk_gb"],
            bridge=cluster_config.network_bridge,
        )
        vm_plans.append(cp_plan)

    # Add worker VMs
    for i in range(1, cluster_config.num_workers + 1):
        worker_vm_name = f"talos-worker-{i}"
        worker_plan = VMPlan(
            vm_name=worker_vm_name,
            role="worker",
            target_node="",
            cpu=reqs["worker"]["cpu"],
            ram_mb=reqs["worker"]["ram_mb"],
            disk_gb=reqs["worker"]["disk_gb"],
            bridge=cluster_config.network_bridge,
        )
        vm_plans.append(worker_plan)

    # Distribute VMs across nodes
    controlplane_vm_names = [vm.vm_name for vm in vm_plans if vm.role == "controlplane"]
    assignment = distribute_vms_across_nodes(
        nodes=topology.available_nodes,
        vm_plans=vm_plans,
        control_plane_roles=controlplane_vm_names,
    )

    # Update target_node for each VM
    for vm in vm_plans:
        vm.target_node = assignment[vm.vm_name]

    # Allocate static IPs if configured
    if not cluster_config.dhcp_mode:
        # Allocate IPs for all VMs (including management, CP, workers)
        num_ips_needed = len(vm_plans)
        allocated_ips = allocate_ips(
            network_cidr=cluster_config.network_cidr,
            bridge=cluster_config.network_bridge,
            mode="static",
            count=num_ips_needed,
            start_ip=cluster_config.ip_range_start,
            end_ip=cluster_config.ip_range_end,
            reserved=[],  # Could include gateway, etc.
        )

        # Assign IPs to VMs in order (management first, then CP, then workers)
        for vm, ip in zip(vm_plans, allocated_ips):
            vm.ip_address = ip

    return vm_plans


def validate_resources(plans: List[VMPlan], available_nodes: List[NodeInfo]) -> None:
    """
    Validate that the VM plans can be accommodated by available nodes.

    Checks that:
    - Each node has sufficient CPU, RAM, and disk for assigned VMs
    - No node is over-allocated

    Args:
        plans: List of VMPlan objects with target_node assigned
        available_nodes: List of NodeInfo with current resource state

    Raises:
        ValueError: If any node lacks sufficient resources
    """
    # Collect all assigned VMs by node
    vms_by_node: Dict[str, List[VMPlan]] = {}
    for vm in plans:
        if not vm.target_node:
            raise ValueError(f"VM {vm.vm_name} has no target_node assigned")
        vms_by_node.setdefault(vm.target_node, []).append(vm)

    # Build node lookup
    nodes_by_id = {node.id: node for node in available_nodes}

    # Check each node
    for node_id, vms in vms_by_node.items():
        if node_id not in nodes_by_id:
            raise ValueError(f"Unknown node: {node_id}")

        node = nodes_by_id[node_id]

        # Sum resources needed
        needed_cpu = sum(vm.cpu for vm in vms)
        needed_ram_mb = sum(vm.ram_mb for vm in vms)
        needed_disk_gb = sum(vm.disk_gb for vm in vms)

        # Check against available (total - used)
        available_cpu = node.available_cpu
        available_ram_mb = node.available_ram_mb
        available_disk_gb = node.available_disk_gb

        if needed_cpu > available_cpu:
            raise ValueError(
                f"Node {node_id}: insufficient CPU. "
                f"Need {needed_cpu}, have {available_cpu} available "
                f"(total {node.total_cpu}, used {node.used_cpu})"
            )
        if needed_ram_mb > available_ram_mb:
            raise ValueError(
                f"Node {node_id}: insufficient RAM. "
                f"Need {needed_ram_mb}MB, have {available_ram_mb}MB available "
                f"(total {node.total_ram_mb}MB, used {node.used_ram_mb}MB)"
            )
        if needed_disk_gb > available_disk_gb:
            raise ValueError(
                f"Node {node_id}: insufficient disk. "
                f"Need {needed_disk_gb}GB, have {available_disk_gb}GB available "
                f"(total {node.total_disk_gb}GB, used {node.used_disk_gb}GB)"
            )


def optimize_placement(
    cluster_config: ClusterConfig,
    topology: ClusterTopology,
) -> List[VMPlan]:
    """
    Generate an optimized placement plan with best-fit node assignment.

    This is a convenience wrapper that:
    1. Generates the VM plan
    2. Validates resources
    3. Returns the plan if validation succeeds

    Args:
        cluster_config: Cluster configuration
        topology: Discovered cluster topology

    Returns:
        Validated list of VMPlan objects

    Raises:
        ValueError: If plan is invalid or resources insufficient
    """
    plans = generate_vm_plan(cluster_config, topology)
    validate_resources(plans, topology.available_nodes)
    return plans


# Example unit tests:
"""
def test_discover_cluster_topology(mocker):
    mock_api = mocker.Mock()
    mock_api.list_nodes.return_value = [
        {"id": "pve1", "status": "online"},
        {"id": "pve2", "status": "offline"},
    ]
    mock_api.get_node_resources.return_value = {
        "cpu": {"cores": 8, "usage": 0.25},
        "memory": {"total": 16 * 1024**3, "used": 4 * 1024**3},
        "rootfs": {"total": 500 * 1024**3, "used": 100 * 1024**3},
    }
    mock_api.list_networks.return_value = [
        {"iface": "vmbr0", "type": "bridge", "active": True}
    ]

    topology = discover_cluster_topology(mock_api)

    assert len(topology.available_nodes) == 1  # Only online node
    assert topology.available_nodes[0].id == "pve1"
    assert topology.available_nodes[0].total_cpu == 8
    assert topology.available_nodes[0].available_cpu == 6.0  # 8 * 0.75

def test_calculate_resource_requirements():
    total_available = {"total_cpu": 12.0, "total_ram_mb": 32768, "total_disk_gb": 1000}
    config = ClusterConfig(num_controlplane=3, num_workers=4, management_cpu=2, management_ram_mb=4096)

    reqs = calculate_resource_requirements(total_available, 3, 4, config)

    assert reqs["management"]["cpu"] == 2
    assert reqs["management"]["ram_mb"] == 4096
    # 3 CP * 2 = 6 CPU, 4 workers * 2 = 8 CPU, + 2 management = 16 total needed
    assert reqs["summary"]["total_cpu_needed"] == 16

def test_distribute_vms_across_nodes():
    nodes = [
        NodeInfo("pve1", total_cpu=16, total_ram_mb=64000, total_disk_gb=2000),
        NodeInfo("pve2", total_cpu=16, total_ram_mb=64000, total_disk_gb=2000),
        NodeInfo("pve3", total_cpu=16, total_ram_mb=64000, total_disk_gb=2000),
    ]
    vm_plans = [
        VMPlan("mgmt", "management", "", 2, 4096, 32),
        VMPlan("cp1", "controlplane", "", 2, 4096, 50),
        VMPlan("cp2", "controlplane", "", 2, 4096, 50),
        VMPlan("cp3", "controlplane", "", 2, 4096, 50),
        VMPlan("w1", "worker", "", 2, 4096, 50),
        VMPlan("w2", "worker", "", 2, 4096, 50),
    ]

    assignment = distribute_vms_across_nodes(nodes, vm_plans)

    # Check control plane spread
    cp_nodes = [assignment["cp1"], assignment["cp2"], assignment["cp3"]]
    assert len(set(cp_nodes)) == 3, "Control plane nodes must be on distinct hosts"
    # Check all VMs assigned
    assert len(assignment) == 6

def test_allocate_ips_static():
    ips = allocate_ips(
        network_cidr="192.168.1.0/24",
        bridge="vmbr0",
        mode="static",
        count=5,
        start_ip="192.168.1.100",
        end_ip="192.168.1.200",
        reserved=["192.168.1.100", "192.168.1.101"]
    )
    assert len(ips) == 5
    assert "192.168.1.100" not in ips
    assert "192.168.1.101" not in ips
    assert ips[0] == "192.168.1.102"

def test_generate_vm_plan():
    config = ClusterConfig(num_controlplane=3, num_workers=2, dhcp_mode=True, network_bridge="vmbr0")
    topology = ClusterTopology(
        nodes=[],
        networks=[],
        available_nodes=[
            NodeInfo("pve1", total_cpu=8, total_ram_mb=32000, total_disk_gb=1000, used_cpu=0, used_ram_mb=0, used_disk_gb=0),
            NodeInfo("pve2", total_cpu=8, total_ram_mb=32000, total_disk_gb=1000, used_cpu=0, used_ram_mb=0, used_disk_gb=0),
            NodeInfo("pve3", total_cpu=8, total_ram_mb=32000, total_disk_gb=1000, used_cpu=0, used_ram_mb=0, used_disk_gb=0),
        ]
    )

    plans = generate_vm_plan(config, topology)

    assert len(plans) == 6  # 1 mgmt + 3 cp + 2 workers
    roles = [p.role for p in plans]
    assert roles.count("management") == 1
    assert roles.count("controlplane") == 3
    assert roles.count("worker") == 2
    # All VMs should have target_node assigned
    for plan in plans:
        assert plan.target_node in ["pve1", "pve2", "pve3"]
    # In DHCP mode, no IPs should be assigned
    for plan in plans:
        assert plan.ip_address is None

def test_validate_resources_success():
    nodes = [
        NodeInfo("pve1", total_cpu=8, total_ram_mb=32000, total_disk_gb=500),
        NodeInfo("pve2", total_cpu=8, total_ram_mb=32000, total_disk_gb=500),
    ]
    plans = [
        VMPlan("cp1", "controlplane", "pve1", 2, 4096, 50),
        VMPlan("cp2", "controlplane", "pve2", 2, 4096, 50),
    ]

    # Should not raise
    validate_resources(plans, nodes)

def test_validate_resources_failure():
    nodes = [
        NodeInfo("pve1", total_cpu=2, total_ram_mb=4096, total_disk_gb=100),
    ]
    plans = [
        VMPlan("cp1", "controlplane", "pve1", 4, 8192, 60),  # Exceeds resources
    ]

    with pytest.raises(ValueError, match="insufficient"):
        validate_resources(plans, nodes)

def test_insufficient_nodes_for_controlplane():
    nodes = [
        NodeInfo("pve1", total_cpu=8, total_ram_mb=32000, total_disk_gb=500),
    ]
    vm_plans = [
        VMPlan("cp1", "controlplane", "", 2, 4096, 50),
        VMPlan("cp2", "controlplane", "", 2, 4096, 50),
        VMPlan("cp3", "controlplane", "", 2, 4096, 50),
    ]

    with pytest.raises(ValueError, match="Not enough nodes"):
        distribute_vms_across_nodes(nodes, vm_plans)

def test_allocate_ips_insufficient():
    with pytest.raises(ValueError, match="Insufficient IP addresses"):
        allocate_ips(
            network_cidr="192.168.1.0/30",  # Only 4 IPs total
            bridge="vmbr0",
            mode="static",
            count=10,
            start_ip="192.168.1.1",
            end_ip="192.168.1.4"
        )
"""
