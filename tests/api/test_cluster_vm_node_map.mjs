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
  bridge: 'vmbr0',
  start_vmid: 200,
  vip_ip: '192.168.1.50',
  start_ip: '192.168.1.51',
  node_prefix_length: 24,
  gateway_ip: '192.168.1.1',
  dns_servers: ['1.1.1.1', '8.8.8.8'],
  dns_domain: 'lab.local',
  vm_node_map: {
    'cp-1': 'pve-a',
    'worker-1': 'pve-b',
    'worker-2': 'pve-a',
  },
  vm_size_map: {
    'cp-1': { cpu: 2, memory_mb: 5120, disk_gb: 10 },
    'worker-1': { cpu: 4, memory_mb: 8192, disk_gb: 60 },
    'worker-2': { cpu: 4, memory_mb: 8192, disk_gb: 60 },
  },
};

const env = {
  PROXMOX_NODE: 'pve-a',
  PROXMOX_STORAGE_POOL: 'local-lvm',
  PROXMOX_FILE_DATASTORE: 'local',
};

test('cluster builder preserves valid vm_node_map and vm_size_map assignments', () => {
  const result = buildClusterFromRequest(
    {
      ...baseBody,
      vm_ip_map: {
        'cp-1': '192.168.1.61',
        'worker-1': '192.168.1.62',
        'worker-2': '192.168.1.63',
      },
    },
    env,
    { allowedVmHosts: ['pve-a', 'pve-b'] }
  );

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
  assert.equal(result.cluster.vm_size_map['worker-1'].disk_gb, 60);
  assert.equal(result.cluster.worker_disk_gb, 60);
});

test('cluster builder requires a vm_node_map instead of fabricating one', () => {
  const { vm_node_map, ...withoutNodeMap } = baseBody;
  const result = buildClusterFromRequest(withoutNodeMap, env, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /vm_node_map is required/);
});

test('cluster builder requires a vm_size_map instead of fabricating one', () => {
  const { vm_size_map, ...withoutSizeMap } = baseBody;
  const result = buildClusterFromRequest(withoutSizeMap, env, {
    allowedVmHosts: ['pve-a', 'pve-b'],
  });

  assert.equal(result.ok, false);
  assert.match(result.error, /vm_size_map is required/);
});

test('cluster builder accepts worker sizes beyond the old 64 vCPU / 8192 GiB caps', () => {
  const result = buildClusterFromRequest(
    {
      ...baseBody,
      vm_size_map: {
        'cp-1': { cpu: 2, memory_mb: 5120, disk_gb: 10 },
        'worker-1': { cpu: 94, memory_mb: 232000, disk_gb: 12000 },
        'worker-2': { cpu: 10, memory_mb: 50000, disk_gb: 9000 },
      },
    },
    env,
    { allowedVmHosts: ['pve-a', 'pve-b'] }
  );

  assert.equal(result.ok, true);
  assert.equal(result.cluster.vm_size_map['worker-1'].cpu, 94);
  assert.equal(result.cluster.vm_size_map['worker-1'].disk_gb, 12000);
});

test('cluster builder rejects stale vm_node_map host names', () => {
  const result = buildClusterFromRequest(
    {
      ...baseBody,
      vm_node_map: {
        'cp-1': 'pve-a',
        'worker-1': 'stale-host',
        'worker-2': 'pve-b',
      },
    },
    env,
    { allowedVmHosts: ['pve-a', 'pve-b'] }
  );

  assert.equal(result.ok, false);
  assert.match(result.error, /unknown Proxmox host stale-host/);
});

test('cluster builder stores a resource profile derived from the vm_size_map', () => {
  const result = buildClusterFromRequest(
    {
      ...baseBody,
      worker_count: 3,
      vm_node_map: {
        'cp-1': 'pve-a',
        'worker-1': 'pve-a',
        'worker-2': 'pve-b',
        'worker-3': 'pve-b',
      },
      vm_size_map: {
        'cp-1': { cpu: 2, memory_mb: 5120, disk_gb: 10 },
        'worker-1': { cpu: 4, memory_mb: 8192, disk_gb: 60 },
        'worker-2': { cpu: 4, memory_mb: 8192, disk_gb: 60 },
        'worker-3': { cpu: 4, memory_mb: 8192, disk_gb: 60 },
      },
      vm_ip_map: {
        'cp-1': '192.168.1.61',
        'worker-1': '192.168.1.62',
        'worker-2': '192.168.1.63',
        'worker-3': '192.168.1.64',
      },
    },
    env,
    { allowedVmHosts: ['pve-a', 'pve-b'] }
  );

  assert.equal(result.ok, true);
  assert.equal(result.cluster.resource_profile, 'small');
  assert.equal(result.cluster.observability_profile, 'full');
  assert.equal(result.cluster.worker_cpu_total, 12);
  assert.equal(result.cluster.worker_memory_total_mb, 24576);
  assert.match(result.cluster.resource_profile_reason, /12 worker CPU cores/);
});

test('resource profile derivation uses worker vm_size_map thresholds only', () => {
  assert.equal(
    deriveClusterResourceProfile({
      vm_size_map: {
        'worker-1': { cpu: 8, memory_mb: 16384, disk_gb: 10 },
        'worker-2': { cpu: 8, memory_mb: 16384, disk_gb: 10 },
        'worker-3': { cpu: 8, memory_mb: 16384, disk_gb: 10 },
      },
    }).resource_profile,
    'standard'
  );

  assert.equal(
    deriveClusterResourceProfile({
      vm_size_map: {
        'worker-1': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
        'worker-2': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
        'worker-3': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
        'worker-4': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
      },
    }).resource_profile,
    'large'
  );
});

test('missing resource profile fields are added lazily for existing clusters', () => {
  const cluster = ensureClusterResourceProfile({
    id: 'legacy',
    worker_count: 4,
    vm_size_map: {
      'worker-1': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
      'worker-2': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
      'worker-3': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
      'worker-4': { cpu: 8, memory_mb: 24576, disk_gb: 10 },
    },
  });

  assert.equal(cluster.resource_profile, 'large');
  assert.equal(cluster.worker_cpu_total, 32);
  assert.equal(cluster.worker_memory_total_mb, 98304);
});
