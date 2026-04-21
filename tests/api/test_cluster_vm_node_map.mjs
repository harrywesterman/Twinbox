import test from 'node:test';
import assert from 'node:assert/strict';

import { buildClusterFromRequest } from '../../manager-api/src/lib/clusters.js';

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
