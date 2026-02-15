"""
Unit tests for the placement engine.

Tests cover:
- discover_cluster_topology
- calculate_resource_requirements
- distribute_vms_across_nodes
- allocate_ips
- generate_vm_plan
"""

import pytest
from twinbox.shared.placement import (
    discover_cluster_topology,
    calculate_resource_requirements,
    distribute_vms_across_nodes,
    allocate_ips,
    generate_vm_plan,
    NodeResources,
    VMSpec,
    ClusterPlan
)


class TestDiscoverClusterTopology:
    """Tests for discover_cluster_topology function."""

    def test_basic_discovery(self):
        """Test basic topology discovery with 3 nodes."""
        nodes_data = [
            {
                'node': 'pve1',
                'total_cpu': 16,
                'total_memory': 128 * 1024,  # 128GB in MB
                'total_disk': 1000 * 1024**3,  # 1000GB in bytes
                'used_cpu': 2,
                'used_memory': 16 * 1024,  # 16GB
                'used_disk': 200 * 1024**3,  # 200GB
            },
            {
                'node': 'pve2',
                'total_cpu': 16,
                'total_memory': 128 * 1024,
                'total_disk': 1000 * 1024**3,
                'used_cpu': 4,
                'used_memory': 32 * 1024,
                'used_disk': 300 * 1024**3,
            },
            {
                'node': 'pve3',
                'total_cpu': 16,
                'total_memory': 128 * 1024,
                'total_disk': 1000 * 1024**3,
                'used_cpu': 1,
                'used_memory': 8 * 1024,
                'used_disk': 100 * 1024**3,
            }
        ]

        nodes = discover_cluster_topology(nodes_data)

        assert len(nodes) == 3

        # Check pve1
        pve1 = next(n for n in nodes if n.name == 'pve1')
        assert pve1.available_cpu == 14
        assert pve1.available_memory_gb == pytest.approx(112.0)  # (128-16)/1024
        assert pve1.available_disk_gb == pytest.approx(800.0)

        # Check pve2
        pve2 = next(n for n in nodes if n.name == 'pve2')
        assert pve2.available_cpu == 12
        assert pve2.available_memory_gb == pytest.approx(96.0)

        # Check pve3 (most available)
        pve3 = next(n for n in nodes if n.name == 'pve3')
        assert pve3.available_cpu == 15
        assert pve3.available_memory_gb == pytest.approx(120.0)

    def test_empty_nodes(self):
        """Test with no nodes."""
        nodes = discover_cluster_topology([])
        assert len(nodes) == 0

    def test_missing_fields_defaults(self):
        """Test handling of missing fields with defaults."""
        nodes_data = [
            {
                'node': 'pve1',
                # Missing some fields - they should default to 0
            }
        ]
        nodes = discover_cluster_topology(nodes_data)
        assert len(nodes) == 1
        assert nodes[0].available_cpu == 0
        assert nodes[0].available_memory_gb == 0.0
        assert nodes[0].available_disk_gb == 0.0


class TestCalculateResourceRequirements:
    """Tests for calculate_resource_requirements function."""

    def test_basic_calculation(self):
        """Test basic resource calculation."""
        mgmt, cp, workers = calculate_resource_requirements(
            management_cpu=4,
            management_memory_gb=8.0,
            management_disk_gb=50.0,
            num_controlplane=3,
            num_workers=5
        )

        # Check management VM
        assert mgmt.role == "management"
        assert mgmt.cpu == 4
        assert mgmt.memory_gb == 8.0
        assert mgmt.disk_gb == 50.0

        # Check control plane VMs
        assert len(cp) == 3
        for cp_vm in cp:
            assert cp_vm.role == "controlplane"
            assert cp_vm.cpu == 2  # default
            assert cp_vm.memory_gb == 4.0  # default
            assert cp_vm.disk_gb == 20.0  # default

        # Check worker VMs
        assert len(workers) == 5
        for worker in workers:
            assert worker.role == "worker"
            assert worker.cpu == 2
            assert worker.memory_gb == 4.0
            assert worker.disk_gb == 20.0

    def test_custom_specs(self):
        """Test with custom control plane and worker specs."""
        mgmt, cp, workers = calculate_resource_requirements(
            management_cpu=4,
            management_memory_gb=8.0,
            management_disk_gb=50.0,
            num_controlplane=2,
            num_workers=3,
            controlplane_cpu=4,
            controlplane_memory_gb=8.0,
            controlplane_disk_gb=40.0,
            worker_cpu=4,
            worker_memory_gb=8.0,
            worker_disk_gb=40.0
        )

        assert cp[0].cpu == 4
        assert cp[0].memory_gb == 8.0
        assert cp[0].disk_gb == 40.0

        assert workers[0].cpu == 4
        assert workers[0].memory_gb == 8.0
        assert workers[0].disk_gb == 40.0

    def test_vm_names(self):
        """Test that VM names are auto-generated correctly."""
        mgmt, cp, workers = calculate_resource_requirements(
            management_cpu=4,
            management_memory_gb=8.0,
            management_disk_gb=50.0,
            num_controlplane=2,
            num_workers=3
        )

        assert mgmt.name == "management"
        assert cp[0].name == "controlplane-0"
        assert cp[1].name == "controlplane-1"
        assert workers[0].name == "worker-0"
        assert workers[1].name == "worker-1"
        assert workers[2].name == "worker-2"

    def test_zero_vms(self):
        """Test with zero control plane or workers."""
        mgmt, cp, workers = calculate_resource_requirements(
            management_cpu=4,
            management_memory_gb=8.0,
            management_disk_gb=50.0,
            num_controlplane=0,
            num_workers=0
        )

        assert len(cp) == 0
        assert len(workers) == 0


class TestDistributeVMsAcrossNodes:
    """Tests for distribute_vms_across_nodes function."""

    def test_control_plane_ha_distribution(self):
        """Test that control plane VMs are distributed across distinct nodes."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=1000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=1000.0,
                vm_count=0
            ),
            NodeResources(
                name="node2",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=1000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=1000.0,
                vm_count=0
            ),
            NodeResources(
                name="node3",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=1000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=1000.0,
                vm_count=0
            )
        ]

        management_vm = VMSpec(name="management", role="management", cpu=4, memory_gb=8.0, disk_gb=50.0)
        controlplane_vms = [
            VMSpec(name="cp1", role="controlplane", cpu=2, memory_gb=4.0, disk_gb=20.0),
            VMSpec(name="cp2", role="controlplane", cpu=2, memory_gb=4.0, disk_gb=20.0),
            VMSpec(name="cp3", role="controlplane", cpu=2, memory_gb=4.0, disk_gb=20.0)
        ]
        worker_vms = []  # No workers for this test

        assignments, updated_nodes = distribute_vms_across_nodes(nodes, management_vm, controlplane_vms, worker_vms)

        # Check that all 3 control plane VMs are on different nodes
        cp_nodes = set()
        for node_name, vms in assignments.items():
            cp_on_node = [vm for vm in vms if vm.role == 'controlplane']
            cp_nodes.update([node_name for _ in cp_on_node])

        assert len(cp_nodes) == 3, "Control plane VMs should be distributed across 3 distinct nodes"

        # Check that management is placed on one of the nodes
        mgmt_found = False
        for vms in assignments.values():
            if any(vm.name == "management" for vm in vms):
                mgmt_found = True
                break
        assert mgmt_found, "Management VM should be placed"

    def test_no_overload(self):
        """Test that nodes are not overloaded beyond available resources."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=8,
                total_memory_gb=32.0,
                total_disk_gb=200.0,
                available_cpu=8,
                available_memory_gb=32.0,
                available_disk_gb=200.0,
                vm_count=0
            )
        ]

        management_vm = VMSpec(name="management", role="management", cpu=4, memory_gb=8.0, disk_gb=50.0)
        controlplane_vms = [
            VMSpec(name="cp1", role="controlplane", cpu=2, memory_gb=4.0, disk_gb=20.0)
        ]
        worker_vms = [
            VMSpec(name="w1", role="worker", cpu=2, memory_gb=4.0, disk_gb=20.0)
        ]

        assignments, updated_nodes = distribute_vms_across_nodes(nodes, management_vm, controlplane_vms, worker_vms)

        # Check node1
        node1_vms = assignments['node1']
        total_cpu = sum(vm.cpu for vm in node1_vms)
        total_mem = sum(vm.memory_gb for vm in node1_vms)
        total_disk = sum(vm.disk_gb for vm in node1_vms)

        assert total_cpu <= 8
        assert total_mem <= 32.0
        assert total_disk <= 200.0

    def test_insufficient_resources_raises(self):
        """Test that placement fails with insufficient resources."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=2,
                total_memory_gb=4.0,
                total_disk_gb=20.0,
                available_cpu=2,
                available_memory_gb=4.0,
                available_disk_gb=20.0,
                vm_count=0
            )
        ]

        management_vm = VMSpec(name="management", role="management", cpu=4, memory_gb=8.0, disk_gb=50.0)
        controlplane_vms = []
        worker_vms = []

        with pytest.raises(ValueError, match="Cannot place management VM"):
            distribute_vms_across_nodes(nodes, management_vm, controlplane_vms, worker_vms)

    def test_empty_vms(self):
        """Test with no VMs to place."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=1000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=1000.0,
                vm_count=0
            )
        ]

        management_vm = VMSpec(name="management", role="management", cpu=4, memory_gb=8.0, disk_gb=50.0)
        controlplane_vms = []
        worker_vms = []

        assignments, updated_nodes = distribute_vms_across_nodes(nodes, management_vm, controlplane_vms, worker_vms)

        # Should still place management VM
        assert len(assignments['node1']) == 1
        assert assignments['node1'][0].name == "management"


class TestAllocateIPs:
    """Tests for allocate_ips function."""

    def test_static_allocation_sequential(self):
        """Test sequential IP allocation in static mode."""
        node_assignments = {
            'node1': [
                VMSpec(name="management", role="management", cpu=4, memory_gb=8.0, disk_gb=50.0),
            ],
            'node2': [
                VMSpec(name="cp1", role="controlplane", cpu=2, memory_gb=4.0, disk_gb=20.0),
                VMSpec(name="cp2", role="controlplane", cpu=2, memory_gb=4.0, disk_gb=20.0)
            ]
        }

        ip_allocations = allocate_ips(
            node_assignments,
            network_base="192.168.1",
            start_ip=10,
            use_dhcp=False
        )

        assert len(ip_allocations) == 3

        # Check IPs are sequential
        ips = list(ip_allocations.values())
        assert "192.168.1.10" in ips
        assert "192.168.1.11" in ips
        assert "192.168.1.12" in ips

        # Each VM gets exactly one IP
        assert all(ip is not None for ip in ips)

    def test_no_duplicate_ips(self):
        """Test that allocated IPs are unique."""
        node_assignments = {
            'node1': [
                VMSpec(name=f"vm{i}", role="worker", cpu=2, memory_gb=4.0, disk_gb=20.0)
                for i in range(10)
            ]
        }

        ip_allocations = allocate_ips(node_assignments, start_ip=100)

        ips = list(ip_allocations.values())
        assert len(ips) == len(set(ips)), "All IPs should be unique"

    def test_dhcp_mode(self):
        """Test DHCP mode returns empty dict."""
        node_assignments = {
            'node1': [
                VMSpec(name="management", role="management", cpu=4, memory_gb=8.0, disk_gb=50.0),
            ]
        }

        ip_allocations = allocate_ips(node_assignments, use_dhcp=True)
        assert ip_allocations == {}

    def test_custom_network_base(self):
        """Test with custom network base."""
        node_assignments = {
            'node1': [
                VMSpec(name="vm1", role="worker", cpu=2, memory_gb=4.0, disk_gb=20.0),
            ]
        }

        ip_allocations = allocate_ips(node_assignments, network_base="10.0.0", start_ip=5)

        assert "10.0.0.5" in ip_allocations.values()


class TestGenerateVMPlan:
    """Tests for generate_vm_plan function."""

    def test_full_plan_generation(self):
        """Test complete plan generation with all components."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            ),
            NodeResources(
                name="node2",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            ),
            NodeResources(
                name="node3",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            )
        ]

        management_spec = {'cpu': 4, 'memory_gb': 8.0, 'disk_gb': 50.0}
        network_config = {
            'network_base': '192.168.1',
            'start_ip': 100,
            'use_dhcp': False
        }

        plan = generate_vm_plan(
            nodes=nodes,
            management_spec=management_spec,
            num_controlplane=3,
            num_workers=5,
            network_config=network_config
        )

        # Check plan structure
        assert isinstance(plan, ClusterPlan)
        assert plan.management_vm is not None
        assert len(plan.controlplane_vms) == 3
        assert len(plan.worker_vms) == 5

        # Check that VMs have IPs
        assert plan.management_vm.ip_address is not None
        assert all(vm.ip_address is not None for vm in plan.controlplane_vms)
        assert all(vm.ip_address is not None for vm in plan.worker_vms)

        # Check node assignments
        assert len(plan.node_assignments) > 0
        total_assigned = sum(len(vms) for vms in plan.node_assignments.values())
        assert total_assigned == 9  # 1 + 3 + 5

    def test_plan_distribution_ha(self):
        """Test that plan has HA properties."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            ),
            NodeResources(
                name="node2",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            ),
            NodeResources(
                name="node3",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            )
        ]

        plan = generate_vm_plan(
            nodes=nodes,
            management_spec={'cpu': 2, 'memory_gb': 4.0, 'disk_gb': 20.0},
            num_controlplane=3,
            num_workers=3,
            network_config={'use_dhcp': False, 'start_ip': 10}
        )

        # Check that control plane nodes are on distinct hosts
        cp_assignments = {}
        for node_name, vms in plan.node_assignments.items():
            cp_on_node = [vm for vm in vms if vm.role == 'controlplane']
            if cp_on_node:
                cp_assignments[node_name] = cp_on_node

        # Should have control plane VMs on at least 3 distinct nodes (or fewer if not possible due to node count)
        # With 3 nodes and 3 control plane VMs, they should be distributed
        assert len(cp_assignments) >= min(3, len(nodes))

    def test_dhcp_plan(self):
        """Test plan in DHCP mode."""
        nodes = [
            NodeResources(
                name="node1",
                total_cpu=16,
                total_memory_gb=128.0,
                total_disk_gb=2000.0,
                available_cpu=16,
                available_memory_gb=128.0,
                available_disk_gb=2000.0,
                vm_count=0
            )
        ]

        plan = generate_vm_plan(
            nodes=nodes,
            management_spec={'cpu': 4, 'memory_gb': 8.0, 'disk_gb': 50.0},
            num_controlplane=1,
            num_workers=2,
            network_config={'use_dhcp': True}
        )

        # In DHCP mode, IPs should not be allocated
        assert plan.management_vm.ip_address is None
        assert all(vm.ip_address is None for vm in plan.controlplane_vms)
        assert all(vm.ip_address is None for vm in plan.worker_vms)
