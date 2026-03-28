import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildProvisionPlacementBoard,
  buildProvisionScaleSummary,
  buildScaledProvisionInputs,
  formatMemoryMb,
} from '../src/provision-scale.js';

const stepInputs = [
  { id: 'scale_percent', default: 30, min: 0, max: 100 },
  { id: 'controlplane_count', default: 1, min: 1, max: 15 },
  { id: 'worker_count', default: 2, min: 0, max: 200 },
  { id: 'cpu_cores', default: 2, min: 1, max: 64 },
  { id: 'memory_mb', default: 4096, min: 512, max: 1048576 },
  { id: 'disk_gb', default: 20, min: 10, max: 8192 },
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

test('scale 30 preserves the default VM footprint', () => {
  const values = buildScaledProvisionInputs(30, stepInputs, {}, new Set(), largeClusterResources);

  assert.equal(values.scale_percent, 30);
  assert.equal(values.controlplane_count, 1);
  assert.equal(values.worker_count, 2);
  assert.equal(values.cpu_cores, 2);
  assert.equal(values.memory_mb, 4096);
  assert.equal(values.disk_gb, 20);
});

test('higher scale percentages grow the VM footprint and totals', () => {
  const values = buildScaledProvisionInputs(100, stepInputs, {}, new Set(), largeClusterResources);
  const summary = buildProvisionScaleSummary(values.scale_percent, stepInputs, values, largeClusterResources);

  assert.ok(values.controlplane_count >= 1);
  assert.ok(values.worker_count >= 2);
  assert.ok(values.cpu_cores >= 2);
  assert.ok(values.memory_mb >= 4096);
  assert.ok(values.disk_gb >= 20);
  assert.ok(summary.total_nodes >= 3);
  assert.ok(summary.total_memory_mb >= 12288);
  assert.ok(summary.total_disk_gb >= 60);
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

  assert.equal(board.vmPlan.length, 3);
  assert.equal(board.hostCards.length, 2);
  assert.equal(board.hostCards[0].activeVmCount, 1);
  assert.equal(board.hostCards[1].activeVmCount, 1);
  assert.equal(Object.keys(board.vmNodeMap).length, 3);
  assert.equal(Object.keys(board.suggestedVmNodeMap).length, 3);
  assert.equal(board.unassigned.length, 0);
  assert.ok(new Set(Object.values(board.vmNodeMap)).size >= 2);
  assert.equal(board.hostCards[0].assignments[0].assignmentSource, 'suggested');
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
      'worker-1': initialBoard.vmNodeMap['worker-1'],
    },
  }, balancedPlacementResources);

  assert.equal(remixedBoard.vmNodeMap['cp-1'], 'pve-b');
  assert.equal(remixedBoard.hostCards.find((host) => host.id === 'pve-b').assignments.some((vm) => vm.name === 'cp-1'), true);
  assert.equal(remixedBoard.hostCards.find((host) => host.id === 'pve-b').assignments.find((vm) => vm.name === 'cp-1').assignmentSource, 'user-selected');
  assert.equal(remixedBoard.vmNodeMap['worker-2'], remixedBoard.suggestedVmNodeMap['worker-2']);
});
