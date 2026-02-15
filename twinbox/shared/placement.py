"""
Placement engine for VM distribution across Proxmox nodes.
"""

from dataclasses import dataclass
from typing import List, Dict, Tuple, Optional
import ipaddress


@dataclass
class NodeResources:
    """Represents the resources available on a Proxmox node."""
    name: str
    total_cpu: int
    total_memory_gb: float
    total_disk_gb: float
    available_cpu: int
    available_memory_gb: float
    available_disk_gb: float
    vm_count: int = 0


@dataclass
class VMSpec:
    """Specification for a VM to be created."""
    name: str
    role: str  # 'management', 'controlplane', 'worker'
    cpu: int
    memory_gb: float
    disk_gb: float
    ip_address: Optional[str] = None
    vm_id: Optional[int] = None


@dataclass
class ClusterPlan:
    """Complete plan for cluster deployment."""
    management_vm: VMSpec
    controlplane_vms: List[VMSpec]
    worker_vms: List[VMSpec]
    network_config: Dict
    node_assignments: Dict[str, List[VMSpec]]  # node_name -> list of VMs


def discover_cluster_topology(proxmox_nodes: List[Dict]) -> List[NodeResources]:
    """
    Discover available resources across Proxmox nodes.

    Args:
        proxmox_nodes: List of node data from Proxmox API (each dict should have 'node', 'cpu', 'memory', 'disk')

    Returns:
        List of NodeResources with calculated available resources
    """
    nodes = []
    for node_data in proxmox_nodes:
        # Assume node_data has fields: node, total_cpu, total_memory, total_disk, used_cpu, used_memory, used_disk
        total_cpu = node_data.get('total_cpu', 0)
        total_memory_mb = node_data.get('total_memory', 0)
        total_disk_gb = node_data.get('total_disk', 0) / (1024**3) if node_data.get('total_disk') else 0
        used_cpu = node_data.get('used_cpu', 0)
        used_memory_mb = node_data.get('used_memory', 0)
        used_disk_gb = node_data.get('used_disk', 0) / (1024**3) if node_data.get('used_disk') else 0

        available_cpu = total_cpu - used_cpu
        available_memory_gb = (total_memory_mb - used_memory_mb) / 1024.0
        available_disk_gb = total_disk_gb - used_disk_gb

        node = NodeResources(
            name=node_data.get('node', 'unknown'),
            total_cpu=total_cpu,
            total_memory_gb=total_memory_mb / 1024.0,
            total_disk_gb=total_disk_gb,
            available_cpu=available_cpu,
            available_memory_gb=available_memory_gb,
            available_disk_gb=available_disk_gb,
            vm_count=0
        )
        nodes.append(node)
    return nodes


def calculate_resource_requirements(
    management_cpu: int,
    management_memory_gb: float,
    management_disk_gb: float,
    num_controlplane: int,
    num_workers: int,
    controlplane_cpu: int = 2,
    controlplane_memory_gb: float = 4.0,
    controlplane_disk_gb: float = 20.0,
    worker_cpu: int = 2,
    worker_memory_gb: float = 4.0,
    worker_disk_gb: float = 20.0
) -> Tuple[VMSpec, List[VMSpec], List[VMSpec]]:
    """
    Calculate VM specifications based on requirements.

    Returns:
        (management_vm, controlplane_vms, worker_vms)
    """
    management_vm = VMSpec(
        name="management",
        role="management",
        cpu=management_cpu,
        memory_gb=management_memory_gb,
        disk_gb=management_disk_gb
    )

    controlplane_vms = [
        VMSpec(
            name=f"controlplane-{i}",
            role="controlplane",
            cpu=controlplane_cpu,
            memory_gb=controlplane_memory_gb,
            disk_gb=controlplane_disk_gb
        )
        for i in range(num_controlplane)
    ]

    worker_vms = [
        VMSpec(
            name=f"worker-{i}",
            role="worker",
            cpu=worker_cpu,
            memory_gb=worker_memory_gb,
            disk_gb=worker_disk_gb
        )
        for i in range(num_workers)
    ]

    return management_vm, controlplane_vms, worker_vms


def distribute_vms_across_nodes(
    nodes: List[NodeResources],
    management_vm: VMSpec,
    controlplane_vms: List[VMSpec],
    worker_vms: List[VMSpec]
) -> Tuple[Dict[str, List[VMSpec]], Dict[str, NodeResources]]:
    """
    Distribute VMs across available nodes ensuring:
    - Control plane nodes go to distinct hosts (for HA)
    - No node is overloaded beyond its available resources
    - Even distribution if possible

    Returns:
        (node_assignments, updated_nodes) where node_assignments maps node_name to list of VMs
    """
    # Sort nodes by available resources (most to least)
    sorted_nodes = sorted(nodes, key=lambda n: (n.available_cpu, n.available_memory_gb), reverse=True)

    # Create mutable copies of node resources
    node_states = {node.name: NodeResources(
        name=node.name,
        total_cpu=node.total_cpu,
        total_memory_gb=node.total_memory_gb,
        total_disk_gb=node.total_disk_gb,
        available_cpu=node.available_cpu,
        available_memory_gb=node.available_memory_gb,
        available_disk_gb=node.available_disk_gb,
        vm_count=0
    ) for node in nodes}

    assignments: Dict[str, List[VMSpec]] = {node_name: [] for node_name in node_states.keys()}

    # Place management VM on the node with most available resources
    if management_vm:
        placed = False
        for node_name in sorted(node_states.keys(), key=lambda n: node_states[n].available_cpu, reverse=True):
            node = node_states[node_name]
            if (node.available_cpu >= management_vm.cpu and
                node.available_memory_gb >= management_vm.memory_gb and
                node.available_disk_gb >= management_vm.disk_gb):
                assignments[node_name].append(management_vm)
                node.available_cpu -= management_vm.cpu
                node.available_memory_gb -= management_vm.memory_gb
                node.available_disk_gb -= management_vm.disk_gb
                node.vm_count += 1
                placed = True
                break
        if not placed:
            raise ValueError("Cannot place management VM: insufficient resources on any node")

    # Distribute control plane VMs across distinct nodes (for HA)
    cp_nodes_used = set()
    for cp_vm in controlplane_vms:
        placed = False
        # Try to put each control plane on a different node
        for node_name in sorted(node_states.keys(), key=lambda n: node_states[n].available_cpu, reverse=True):
            node = node_states[node_name]
            if node_name not in cp_nodes_used and node.available_cpu >= cp_vm.cpu and node.available_memory_gb >= cp_vm.memory_gb and node.available_disk_gb >= cp_vm.disk_gb:
                assignments[node_name].append(cp_vm)
                node.available_cpu -= cp_vm.cpu
                node.available_memory_gb -= cp_vm.memory_gb
                node.available_disk_gb -= cp_vm.disk_gb
                node.vm_count += 1
                cp_nodes_used.add(node_name)
                placed = True
                break
        if not placed:
            # If we couldn't place on distinct nodes, try any available node
            for node_name in sorted(node_states.keys(), key=lambda n: node_states[n].available_cpu, reverse=True):
                node = node_states[node_name]
                if node.available_cpu >= cp_vm.cpu and node.available_memory_gb >= cp_vm.memory_gb and node.available_disk_gb >= cp_vm.disk_gb:
                    assignments[node_name].append(cp_vm)
                    node.available_cpu -= cp_vm.cpu
                    node.available_memory_gb -= cp_vm.memory_gb
                    node.available_disk_gb -= cp_vm.disk_gb
                    node.vm_count += 1
                    cp_nodes_used.add(node_name)
                    placed = True
                    break
        if not placed:
            raise ValueError(f"Cannot place control plane VM {cp_vm.name}: insufficient resources")

    # Distribute worker VMs across nodes
    for worker_vm in worker_vms:
        placed = False
        for node_name in sorted(node_states.keys(), key=lambda n: node_states[n].available_cpu, reverse=True):
            node = node_states[node_name]
            if node.available_cpu >= worker_vm.cpu and node.available_memory_gb >= worker_vm.memory_gb and node.available_disk_gb >= worker_vm.disk_gb:
                assignments[node_name].append(worker_vm)
                node.available_cpu -= worker_vm.cpu
                node.available_memory_gb -= worker_vm.memory_gb
                node.available_disk_gb -= worker_vm.disk_gb
                node.vm_count += 1
                placed = True
                break
        if not placed:
            raise ValueError(f"Cannot place worker VM {worker_vm.name}: insufficient resources")

    return assignments, node_states


def allocate_ips(
    node_assignments: Dict[str, List[VMSpec]],
    network_base: str = "192.168.1",
    start_ip: int = 10,
    use_dhcp: bool = False
) -> Dict[VMSpec, str]:
    """
    Allocate IP addresses to VMs.

    Args:
        node_assignments: Mapping of node to VMs
        network_base: Base network (e.g., "192.168.1")
        start_ip: Starting host address (e.g., 10 means .10)
        use_dhcp: If True, returns None or special value for DHCP mode

    Returns:
        Mapping of VMs to IP addresses
    """
    if use_dhcp:
        # In DHCP mode, we don't allocate IPs statically
        return {}

    ip_allocations: Dict[VMSpec, str] = {}
    current_ip = start_ip

    # Flatten all VMs from all nodes
    all_vms = []
    for node_name, vms in node_assignments.items():
        all_vms.extend(vms)

    for vm in all_vms:
        ip = f"{network_base}.{current_ip}"
        # Validate IP
        try:
            ipaddress.IPv4Address(ip)
        except ValueError:
            raise ValueError(f"Invalid IP address: {ip}")
        ip_allocations[vm] = ip
        current_ip += 1

    return ip_allocations


def generate_vm_plan(
    nodes: List[NodeResources],
    management_spec: Dict,
    num_controlplane: int,
    num_workers: int,
    network_config: Dict,
    **kwargs
) -> ClusterPlan:
    """
    Generate complete VM placement plan.

    Args:
        nodes: Available Proxmox nodes
        management_spec: Dict with cpu, memory_gb, disk_gb
        num_controlplane: Number of control plane nodes
        num_workers: Number of worker nodes
        network_config: Network configuration dict
        **kwargs: Additional parameters for VM specs

    Returns:
        ClusterPlan with all details
    """
    # Calculate requirements
    management_vm, controlplane_vms, worker_vms = calculate_resource_requirements(
        management_cpu=management_spec.get('cpu', 4),
        management_memory_gb=management_spec.get('memory_gb', 8.0),
        management_disk_gb=management_spec.get('disk_gb', 50.0),
        num_controlplane=num_controlplane,
        num_workers=num_workers,
        controlplane_cpu=kwargs.get('controlplane_cpu', 2),
        controlplane_memory_gb=kwargs.get('controlplane_memory_gb', 4.0),
        controlplane_disk_gb=kwargs.get('controlplane_disk_gb', 20.0),
        worker_cpu=kwargs.get('worker_cpu', 2),
        worker_memory_gb=kwargs.get('worker_memory_gb', 4.0),
        worker_disk_gb=kwargs.get('worker_disk_gb', 20.0)
    )

    # Distribute VMs
    node_assignments, updated_nodes = distribute_vms_across_nodes(
        nodes, management_vm, controlplane_vms, worker_vms
    )

    # Allocate IPs
    use_dhcp = network_config.get('use_dhcp', False)
    ip_allocations = allocate_ips(
        node_assignments,
        network_base=network_config.get('network_base', '192.168.1'),
        start_ip=network_config.get('start_ip', 10),
        use_dhcp=use_dhcp
    )

    # Assign IPs to VMs
    for vm in [management_vm] + controlplane_vms + worker_vms:
        if not use_dhcp:
            vm.ip_address = ip_allocations.get(vm)

    return ClusterPlan(
        management_vm=management_vm,
        controlplane_vms=controlplane_vms,
        worker_vms=worker_vms,
        network_config=network_config,
        node_assignments=node_assignments
    )
