import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildClusterFromRequest,
  deriveClusterResourceProfile,
  ensureClusterResourceProfile,
} from '../../manager-api/src/lib/clusters.js';

const baseBody = {
  name: 'demo',
  controlplane_count: 1,
  worker_count: 2,
  cpu_cores: 2,
  memory_mb: 4096,
  disk_gb: 20,
  bridge: 'vmbr0',
  start_vmid: 200,
  vip_ip: '192.168.1.50',
  start_ip: '192.168.1.51',
  node_prefix_length: 24,
  gateway_ip: '192.168.1.1',
  dns_servers: ['1.1.1.1', '8.8.8.8'],
  dns_domain: 'lab.local',
};

test('cluster builder preserves valid vm_node_map assignments', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    vm_ip_map: {
      'cp-1': '192.168.1.61',
      'worker-1': '192.168.1.62',
      'worker-2': '192.168.1.63',
    },
    vm_node_map: {
      'cp-1': 'pve-a',
      'worker-1': 'pve-b',
      'worker-2': 'pve-a',
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.cluster.vm_ip_map, {
    'cp-1': '192.168.1.61',
    'worker-1': '192.168.1.62',
    'worker-2': '192.168.1.63',
  });
  assert.equal(result.cluster.start_ip, '192.168.1.61');
  assert.deepEqual(result.cluster.vm_node_map, {
    'cp-1': 'pve-a',
    'worker-1': 'pve-b',
    'worker-2': 'pve-a',
  });
});

test('cluster builder fills missing vm_node_map assignments with allowed hosts', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    vm_node_map: {
      'cp-1': 'pve-b',
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.cluster.vm_node_map, {
    'cp-1': 'pve-b',
    'worker-1': 'pve-b',
    'worker-2': 'pve-a',
  });
});

test('cluster builder no longer falls back to a 100GB worker disk', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    vm_ip_map: {
      'cp-1': '192.168.1.61',
      'worker-1': '192.168.1.62',
      'worker-2': '192.168.1.63',
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, true);
  assert.equal(result.cluster.worker_disk_percent, 100);
  assert.equal(result.cluster.worker_disk_gb, 10);
});

test('cluster builder defaults control planes to 2 vCPU while workers use requested CPU', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    cpu_cores: 6,
    vm_ip_map: {
      'cp-1': '192.168.1.61',
      'worker-1': '192.168.1.62',
      'worker-2': '192.168.1.63',
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, true);
  assert.equal(result.cluster.vm_size_map['cp-1'].cpu, 2);
  assert.equal(result.cluster.vm_size_map['worker-1'].cpu, 6);
  assert.equal(result.cluster.vm_size_map['worker-2'].cpu, 6);
});

test('cluster builder preserves explicit control-plane CPU overrides', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    cpu_cores: 6,
    vm_ip_map: {
      'cp-1': '192.168.1.61',
      'worker-1': '192.168.1.62',
      'worker-2': '192.168.1.63',
    },
    vm_size_map: {
      'cp-1': {
        cpu: 4,
        memory_mb: 3072,
        disk_gb: 10,
      },
      'worker-1': {
        cpu: 6,
        memory_mb: 4096,
        disk_gb: 10,
      },
      'worker-2': {
        cpu: 6,
        memory_mb: 4096,
        disk_gb: 10,
      },
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, true);
  assert.equal(result.cluster.vm_size_map['cp-1'].cpu, 4);
});

test('cluster builder rejects stale vm_node_map host names', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    vm_node_map: {
      'cp-1': 'pve-a',
      'worker-1': 'stale-host',
      'worker-2': 'pve-b',
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /unknown Proxmox host stale-host/);
});

test('cluster builder stores an automatic small resource profile for homelab defaults', () => {
  const result = buildClusterFromRequest({
    ...baseBody,
    worker_count: 3,
    cpu_cores: 4,
    memory_mb: 10240,
    vm_ip_map: {
      'cp-1': '192.168.1.61',
      'worker-1': '192.168.1.62',
      'worker-2': '192.168.1.63',
      'worker-3': '192.168.1.64',
    },
  }, {
    PROXMOX_NODE: 'pve-a',
    PROXMOX_STORAGE_POOL: 'local-lvm',
    PROXMOX_FILE_DATASTORE: 'local',
  }, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, true);
  assert.equal(result.cluster.resource_profile, 'small');
  assert.equal(result.cluster.observability_profile, 'full');
  assert.equal(result.cluster.worker_cpu_total, 12);
  assert.equal(result.cluster.worker_memory_total_mb, 30720);
  assert.match(result.cluster.resource_profile_reason, /12 worker CPU cores/);
});

test('resource profile derivation uses worker capacity thresholds only', () => {
  assert.equal(deriveClusterResourceProfile({
    worker_count: 3,
    cpu_cores: 8,
    memory_mb: 16384,
  }).resource_profile, 'standard');

  assert.equal(deriveClusterResourceProfile({
    worker_count: 4,
    cpu_cores: 8,
    memory_mb: 24576,
  }).resource_profile, 'large');
});

test('resource profile derivation honors per-worker vm_size_map overrides', () => {
  const profile = deriveClusterResourceProfile({
    worker_count: 3,
    cpu_cores: 4,
    memory_mb: 10240,
    vm_size_map: {
      'cp-1': { cpu: 16, memory_mb: 65536, disk_gb: 10 },
      'worker-1': { cpu: 8, memory_mb: 16384, disk_gb: 10 },
      'worker-2': { cpu: 8, memory_mb: 16384, disk_gb: 10 },
      'worker-3': { cpu: 8, memory_mb: 16384, disk_gb: 10 },
    },
  });

  assert.equal(profile.resource_profile, 'standard');
  assert.equal(profile.worker_cpu_total, 24);
  assert.equal(profile.worker_memory_total_mb, 49152);
});

test('missing resource profile fields are added lazily for existing clusters', () => {
  const cluster = ensureClusterResourceProfile({
    id: 'legacy',
    worker_count: 4,
    cpu_cores: 8,
    memory_mb: 24576,
  });

  assert.equal(cluster.resource_profile, 'large');
  assert.equal(cluster.worker_cpu_total, 32);
  assert.equal(cluster.worker_memory_total_mb, 98304);
});
