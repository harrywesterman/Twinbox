import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildAutomaticProvisionPlacementResult,
  buildProvisionPlacementBoard,
  buildProvisionScaleSummary,
  buildScaledProvisionInputs,
  getProvisionNodeCount,
  formatMemoryMb,
} from '../src/provision-scale.js';

const stepInputs = [
  { id: 'scale_percent', default: 90, min: 0, max: 100 },
  { id: 'worker_disk_percent', default: 80, min: 10, max: 100 },
  { id: 'controlplane_count', default: 3, min: 1, max: 15 },
  { id: 'worker_count', default: 3, min: 0, max: 200 },
  { id: 'cpu_cores', default: 2, min: 1, max: 64 },
  { id: 'memory_mb', default: 4096, min: 512, max: 1048576 },
];

const largeClusterResources = {
  summary: {
    nodeCount: 4,
    totalMemoryMb: 262144,
    usedMemoryMb: 65536,
    freeMemoryMb: 196608,
    totalDiskGb: 4000,
    usedDiskGb: 1000,
    freeDiskGb: 3000,
    totalCpuCores: 96,
    usedCpuCores: 24,
    freeCpuCores: 72,
  },
};

const balancedPlacementResources = {
  nodes: [
    {
      node: 'pve-a',
      status: 'online',
      maxmem: 17179869184,
      mem: 2147483648,
      maxdisk: 549755813888,
      disk: 107374182400,
      maxcpu: 8,
      cpu: 0.15,
    },
    {
      node: 'pve-b',
      status: 'online',
      maxmem: 17179869184,
      mem: 2147483648,
      maxdisk: 549755813888,
      disk: 107374182400,
      maxcpu: 8,
      cpu: 0.1,
    },
  ],
  vms: [
    {
      node: 'pve-a',
      status: 'running',
      vmid: 200,
    },
    {
      node: 'pve-a',
      status: 'stopped',
      vmid: 201,
    },
    {
      node: 'pve-b',
      status: 'running',
      vmid: 202,
    },
  ],
};

test('scale 90 preserves the default VM footprint', () => {
  const values = buildScaledProvisionInputs(90, stepInputs, {}, new Set(), largeClusterResources);

  assert.equal(values.scale_percent, 90);
  assert.equal(values.controlplane_count, 3);
  assert.equal(values.worker_count, 3);
  assert.equal(values.cpu_cores, 2);
  assert.equal(values.memory_mb, 4096);
  assert.equal(values.worker_disk_percent, 80);
});

test('provision node count falls back to the wizard defaults when the draft is empty', () => {
  assert.equal(getProvisionNodeCount(stepInputs, {}), 6);
  assert.equal(getProvisionNodeCount(stepInputs, { controlplane_count: 2 }), 5);
  assert.equal(getProvisionNodeCount(stepInputs, { controlplane_count: 0, worker_count: 0 }), 1);
});

test('higher scale percentages grow the VM footprint and totals', () => {
  const values = buildScaledProvisionInputs(100, stepInputs, {}, new Set(), largeClusterResources);
  const summary = buildProvisionScaleSummary(values.scale_percent, stepInputs, values, largeClusterResources);

  assert.ok(values.controlplane_count >= 1);
  assert.ok(values.worker_count >= 2);
  assert.ok(values.cpu_cores >= 2);
  assert.ok(values.memory_mb >= 4096);
  assert.ok(summary.total_nodes >= 3);
  assert.ok(summary.total_memory_mb >= 12288);
  assert.equal(summary.worker_disk_percent, 80);
  assert.equal(summary.controlplane_disk_gb, 10);
  assert.equal(summary.worker_disk_gb, 300);
  assert.equal(summary.total_worker_disk_gb, 2400);
});

test('manual overrides stay in place when the scale slider changes', () => {
  const dirty = new Set(['cpu_cores', 'memory_mb']);
  const values = buildScaledProvisionInputs(100, stepInputs, {
    cpu_cores: 8,
    memory_mb: 8192,
  }, dirty, largeClusterResources);

  assert.equal(values.cpu_cores, 8);
  assert.equal(values.memory_mb, 8192);
});

test('memory formatter prefers gigabytes for larger values', () => {
  assert.equal(formatMemoryMb(4096), '4 GB');
  assert.equal(formatMemoryMb(768), '768 MB');
});

test('placement board suggests a host-aware Talos VM layout', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {}, balancedPlacementResources);

  assert.equal(board.vmPlan.length, 6);
  assert.equal(board.hostCards.length, 2);
  assert.equal(board.hostCards[0].activeVmCount, 1);
  assert.equal(board.hostCards[1].activeVmCount, 1);
  assert.equal(Object.keys(board.vmNodeMap).length, 0);
  assert.equal(Object.keys(board.suggestedVmNodeMap).length, 6);
  assert.equal(board.unassigned.length, 6);
  assert.equal(board.hostCards[0].assignments.length, 0);
  assert.equal(board.vmSizeMap['cp-1'].disk_gb, 10);
  assert.ok(board.suggestedVmSizeMap['worker-1'].disk_gb > 100);
});

test('placement board keeps the management VM fixed on its host and exposes its size', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {}, {
    ...balancedPlacementResources,
    vms: [
      ...balancedPlacementResources.vms,
      {
        node: 'pve-b',
        name: 'twinbox-demo-mgt',
        tags: 'twinbox;management;bootstrap',
        status: 'running',
        vmid: 190,
        maxmem: 8589934592,
        maxdisk: 64424509440,
      },
    ],
  });

  assert.deepEqual(board.managementVm, {
    id: 'management-twinbox-demo-mgt',
    name: 'twinbox-demo-mgt',
    label: 'Management VM',
    type: 'management',
    vmid: 190,
    hostId: 'pve-b',
    hostName: 'pve-b',
    cpu: 0,
    memory_mb: 8192,
    disk_gb: 60,
    status: 'running',
    assignmentSource: 'fixed',
    isFixed: true,
    isSuggested: false,
    isUserSelected: false,
  });

  const host = board.hostCards.find((entry) => entry.id === 'pve-b');
  assert.ok(host.assignments.some((vm) => vm.isFixed && vm.name === 'twinbox-demo-mgt'));
  assert.equal(host.assignments.find((vm) => vm.isFixed && vm.name === 'twinbox-demo-mgt').disk_gb, 60);
  assert.equal(host.assignments.find((vm) => vm.isFixed && vm.name === 'twinbox-demo-mgt').memory_mb, 8192);
});

test('placement board sorts hosts alphabetically by name', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {}, {
    nodes: [
      {
        node: 'proxmox',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 549755813888,
        disk: 0,
        maxcpu: 8,
        cpu: 0,
      },
      {
        node: 'pve2',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 549755813888,
        disk: 0,
        maxcpu: 8,
        cpu: 0,
      },
      {
        node: 'pve1',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 549755813888,
        disk: 0,
        maxcpu: 8,
        cpu: 0,
      },
    ],
    vms: [],
  });

  assert.deepEqual(board.hostCards.map((host) => host.name), ['proxmox', 'pve1', 'pve2']);
});

test('placement board preserves manual VM host assignments', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {
    vm_node_map: {
      'cp-1': 'pve-b',
      'worker-1': 'pve-a',
    },
  }, balancedPlacementResources);

  assert.equal(board.vmNodeMap['cp-1'], 'pve-b');
  assert.equal(board.vmNodeMap['worker-1'], 'pve-a');
  assert.equal(board.hostCards.find((host) => host.id === 'pve-b').assignments[0].assignmentSource, 'user-selected');
  assert.equal(board.hostCards.find((host) => host.id === 'pve-a').assignments[0].assignmentSource, 'user-selected');
});

test('placement board keeps manual placements while resuggesting the rest', () => {
  const initialBoard = buildProvisionPlacementBoard(stepInputs, {}, balancedPlacementResources);
  const remixedBoard = buildProvisionPlacementBoard(stepInputs, {
    vm_node_map: {
      'cp-1': 'pve-b',
      'worker-1': initialBoard.suggestedVmNodeMap['worker-1'],
    },
  }, balancedPlacementResources);

  assert.equal(remixedBoard.vmNodeMap['cp-1'], 'pve-b');
  assert.equal(remixedBoard.hostCards.find((host) => host.id === 'pve-b').assignments.some((vm) => vm.name === 'cp-1'), true);
  assert.equal(remixedBoard.hostCards.find((host) => host.id === 'pve-b').assignments.find((vm) => vm.name === 'cp-1').assignmentSource, 'user-selected');
  assert.equal(remixedBoard.vmNodeMap['worker-2'], undefined);
  assert.equal(remixedBoard.suggestedVmNodeMap['worker-2'], initialBoard.suggestedVmNodeMap['worker-2']);
});

test('automatic placement fills pve1, pve2, and pve3 in host order when they can fit them', () => {
  const result = buildAutomaticProvisionPlacementResult(stepInputs, {}, {
    nodes: [
      {
        node: 'proxmox',
        status: 'online',
        maxmem: 2147483648,
        mem: 0,
        maxdisk: 50 * 1024 * 1024 * 1024,
        disk: 8 * 1024 * 1024 * 1024,
        maxcpu: 2,
        cpu: 0,
      },
      {
        node: 'pve1',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 300 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0.99,
      },
      {
        node: 'pve2',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 350 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0.95,
      },
      {
        node: 'pve3',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 400 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0.9,
      },
      {
        node: 'pve4',
        status: 'online',
        maxmem: 17179869184,
        mem: 17050000000,
        maxdisk: 700 * 1024 * 1024 * 1024,
        disk: 650 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0.1,
      },
    ],
    vms: [
      {
        node: 'pve1',
        name: 'twinbox-prd-mgt',
        tags: 'management;bootstrap;cluster-prd',
        status: 'running',
        vmid: 103,
        maxmem: 4294967296,
        maxdisk: 42949672960,
      },
    ],
  });

  assert.equal(result.assigned, 6);
  assert.equal(result.unassigned, 0);
  assert.equal(result.tone, 'success');
  assert.match(result.message, /assigned all 6 Talos VMs/i);
  assert.deepEqual(result.vm_node_map, {
    'cp-1': 'pve1',
    'cp-2': 'pve2',
    'cp-3': 'pve3',
    'worker-1': 'pve1',
    'worker-2': 'pve2',
    'worker-3': 'pve3',
  });
  assert.ok(!Object.values(result.vm_node_map).includes('proxmox'));
  assert.equal(result.vm_size_map['worker-1'].disk_gb, 400);
  assert.equal(result.vm_size_map['worker-2'].disk_gb, 400);
  assert.equal(result.vm_size_map['worker-3'].disk_gb, 400);
});

test('automatic placement leaves overflow VMs unassigned when capacity is constrained', () => {
  const result = buildAutomaticProvisionPlacementResult(stepInputs, {}, {
    nodes: [
      {
        node: 'pve1',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 20 * 1024 * 1024 * 1024,
        disk: 10 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0,
      },
      {
        node: 'pve2',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 20 * 1024 * 1024 * 1024,
        disk: 10 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0,
      },
    ],
    vms: [],
  });

  assert.equal(result.assigned, 2);
  assert.equal(result.unassigned, 4);
  assert.equal(result.tone, 'warning');
  assert.match(result.message, /2 of 6 Talos VMs/i);
  assert.ok(Object.values(result.vm_node_map).filter(Boolean).length < 6);
});

test('automatic placement reports danger when no Talos VM can fit', () => {
  const result = buildAutomaticProvisionPlacementResult(stepInputs, {}, {
    nodes: [
      {
        node: 'pve1',
        status: 'online',
        maxmem: 2147483648,
        mem: 0,
        maxdisk: 0,
        disk: 0,
        maxcpu: 1,
        cpu: 0,
      },
      {
        node: 'pve2',
        status: 'online',
        maxmem: 2147483648,
        mem: 0,
        maxdisk: 0,
        disk: 0,
        maxcpu: 1,
        cpu: 0,
      },
    ],
    vms: [],
  });

  assert.equal(result.assigned, 0);
  assert.equal(result.unassigned, 6);
  assert.equal(result.tone, 'danger');
  assert.match(result.message, /could not place any Talos VMs/i);
});

test('automatic placement uses host free disk instead of a fixed 100GB worker size', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {}, {
    nodes: [
      {
        node: 'pve1',
        status: 'online',
        maxmem: 17179869184,
        mem: 2147483648,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 300 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0.25,
      },
      {
        node: 'pve2',
        status: 'online',
        maxmem: 17179869184,
        mem: 2147483648,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 350 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0,
      },
      {
        node: 'pve3',
        status: 'online',
        maxmem: 17179869184,
        mem: 2147483648,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 400 * 1024 * 1024 * 1024,
        maxcpu: 4,
        cpu: 0,
      },
    ],
    vms: [
      {
        node: 'pve1',
        name: 'twinbox-prd-mgt',
        tags: 'management;bootstrap',
        status: 'running',
        vmid: 103,
        maxmem: 4294967296,
        maxdisk: 42949672960,
      },
    ],
  });

  assert.equal(board.managementVm.hostId, 'pve1');
  assert.equal(Object.values(board.suggestedVmNodeMap).filter(Boolean).length, 6);
  assert.equal(board.hostCards.find((host) => host.id === 'pve1').assignments.some((vm) => vm.isFixed && vm.name === 'twinbox-prd-mgt'), true);
  assert.equal(board.suggestedVmSizeMap['worker-1'].disk_gb, 400);
  assert.equal(board.suggestedVmSizeMap['worker-2'].disk_gb, 400);
  assert.equal(board.suggestedVmSizeMap['worker-3'].disk_gb, 400);
});

test('automatic placement ignores CPU pressure and still follows the host order', () => {
  const result = buildAutomaticProvisionPlacementResult(stepInputs, {}, {
    nodes: [
      {
        node: 'pve1',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 300 * 1024 * 1024 * 1024,
        maxcpu: 1,
        cpu: 0.99,
      },
      {
        node: 'pve2',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 350 * 1024 * 1024 * 1024,
        maxcpu: 1,
        cpu: 0.99,
      },
      {
        node: 'pve3',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 900 * 1024 * 1024 * 1024,
        disk: 400 * 1024 * 1024 * 1024,
        maxcpu: 1,
        cpu: 0.99,
      },
    ],
    vms: [
      {
        node: 'pve1',
        name: 'twinbox-prd-mgt',
        tags: 'twinbox;management;bootstrap;cluster-prd',
        status: 'running',
        vmid: 103,
        maxmem: 4294967296,
        maxdisk: 42949672960,
      },
    ],
  });

  assert.equal(result.tone, 'success');
  assert.equal(result.vm_node_map['cp-1'], 'pve1');
  assert.equal(result.vm_node_map['cp-2'], 'pve2');
  assert.equal(result.vm_node_map['cp-3'], 'pve3');
  assert.equal(result.vm_node_map['worker-1'], 'pve1');
  assert.equal(result.vm_node_map['worker-2'], 'pve2');
  assert.equal(result.vm_node_map['worker-3'], 'pve3');
  assert.equal(result.assigned, 6);
});

test('automatic placement replaces stale manual placements with a fresh suggestion', () => {
  const fresh = buildAutomaticProvisionPlacementResult(stepInputs, {}, balancedPlacementResources);
  const rerun = buildAutomaticProvisionPlacementResult(stepInputs, {
    vm_node_map: {
      'cp-1': 'pve-b',
      'cp-2': 'pve-b',
      'cp-3': 'pve-b',
      'worker-1': 'pve-b',
      'worker-2': 'pve-b',
      'worker-3': 'pve-b',
    },
  }, balancedPlacementResources);

  assert.deepEqual(rerun.vm_node_map, fresh.vm_node_map);
  assert.deepEqual(rerun.vm_size_map, fresh.vm_size_map);
  assert.equal(rerun.assigned, fresh.assigned);
  assert.equal(rerun.unassigned, fresh.unassigned);
});

test('worker disk follows the worker-disk slider share', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {
    worker_disk_percent: 50,
    worker_count: 1,
    vm_node_map: {
      'cp-1': 'pve-a',
      'worker-1': 'pve-a',
    },
  }, {
    nodes: [
      {
        node: 'pve-a',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 214748364800,
        disk: 0,
        maxcpu: 8,
        cpu: 0,
      },
    ],
    vms: [],
  });

  assert.equal(board.vmSizeMap['worker-1'].disk_gb, 100);
  assert.equal(board.vmSizeMap['cp-1'].disk_gb, 10);
});

test('default placement spreads one control plane and one worker across each host', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {}, {
    nodes: [
      {
        node: 'pve-a',
        status: 'online',
        maxmem: 17179869184,
        mem: 2147483648,
        maxdisk: 549755813888,
        disk: 107374182400,
        maxcpu: 8,
        cpu: 0.1,
      },
      {
        node: 'pve-b',
        status: 'online',
        maxmem: 17179869184,
        mem: 2147483648,
        maxdisk: 549755813888,
        disk: 107374182400,
        maxcpu: 8,
        cpu: 0.1,
      },
      {
        node: 'pve-c',
        status: 'online',
        maxmem: 17179869184,
        mem: 2147483648,
        maxdisk: 549755813888,
        disk: 107374182400,
        maxcpu: 8,
        cpu: 0.1,
      },
    ],
    vms: [],
  });

  const hostCounts = new Map(board.hostCards.map((host) => [host.id, 0]));
  for (const hostId of Object.values(board.suggestedVmNodeMap)) {
    hostCounts.set(hostId, (hostCounts.get(hostId) || 0) + 1);
  }

  assert.equal(board.hostCards.length, 3);
  assert.deepEqual([...hostCounts.values()], [2, 2, 2]);
  assert.equal(board.suggestedVmNodeMap['cp-1'], 'pve-a');
  assert.equal(board.suggestedVmNodeMap['worker-1'], 'pve-a');
  assert.equal(board.suggestedVmNodeMap['cp-2'], 'pve-b');
  assert.equal(board.suggestedVmNodeMap['worker-2'], 'pve-b');
  assert.equal(board.suggestedVmNodeMap['cp-3'], 'pve-c');
  assert.equal(board.suggestedVmNodeMap['worker-3'], 'pve-c');
});

test('automatic placement preserves the pve1/pve2/pve3 pairing order', () => {
  const board = buildProvisionPlacementBoard(stepInputs, {}, {
    nodes: [
      {
        node: 'pve-a',
        status: 'online',
        maxmem: 34359738368,
        mem: 0,
        maxdisk: 1099511627776,
        disk: 0,
        maxcpu: 16,
        cpu: 0,
      },
      {
        node: 'pve-b',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 549755813888,
        disk: 0,
        maxcpu: 8,
        cpu: 0,
      },
      {
        node: 'pve-c',
        status: 'online',
        maxmem: 17179869184,
        mem: 0,
        maxdisk: 549755813888,
        disk: 0,
        maxcpu: 8,
        cpu: 0,
      },
    ],
    vms: [
      {
        node: 'pve-b',
        name: 'twinbox-demo-mgt',
        tags: 'management',
        status: 'running',
        vmid: 190,
        maxmem: 4294967296,
        maxdisk: 32212254720,
      },
    ],
  });

  assert.equal(board.suggestedVmNodeMap['cp-1'], 'pve-a');
  assert.equal(board.suggestedVmNodeMap['cp-2'], 'pve-b');
  assert.equal(board.suggestedVmNodeMap['cp-3'], 'pve-c');
  assert.equal(board.suggestedVmNodeMap['worker-1'], 'pve-a');
  assert.equal(board.suggestedVmNodeMap['worker-2'], 'pve-b');
  assert.equal(board.suggestedVmNodeMap['worker-3'], 'pve-c');
  assert.equal(board.hostCards.find((host) => host.id === 'pve-b').assignments[0].isFixed, true);
});
