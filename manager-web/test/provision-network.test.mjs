import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildProvisionVmIpMap,
  buildProvisionVmIpRows,
  validateProvisionVmIpRows,
} from '../src/provision-network.js';

const vmPlan = [
  { name: 'cp-1', label: 'Control plane 1', vmid: 210, type: 'controlplane' },
  { name: 'worker-1', label: 'Worker 1', vmid: 211, type: 'worker' },
  { name: 'worker-2', label: 'Worker 2', vmid: 212, type: 'worker' },
];

test('buildProvisionVmIpRows marks suggestion hits as verified and manual edits as warning', () => {
  const rows = buildProvisionVmIpRows(vmPlan, {
    vm_ip_map: {
      'cp-1': '192.168.2.61',
      'worker-1': '192.168.2.72',
      'worker-2': '192.168.2.63',
    },
  }, {
    vm_ips: ['192.168.2.61', '192.168.2.62', '192.168.2.63'],
  });

  assert.equal(rows[0].status.tone, 'success');
  assert.equal(rows[0].status.label, 'Verified free');
  assert.equal(rows[1].status.tone, 'warning');
  assert.equal(rows[1].status.label, 'Locally edited');
  assert.equal(rows[2].status.tone, 'success');
});

test('buildProvisionVmIpRows and validation flag duplicates and invalid values', () => {
  const rows = buildProvisionVmIpRows(vmPlan, {
    vm_ip_map: {
      'cp-1': '192.168.2.61',
      'worker-1': '192.168.2.61',
      'worker-2': '999.168.2.63',
    },
  }, {
    vm_ips: ['192.168.2.61', '192.168.2.62', '192.168.2.63'],
  });

  const validation = validateProvisionVmIpRows(rows);
  assert.equal(validation.ok, false);
  assert.equal(rows[1].status.tone, 'danger');
  assert.equal(rows[1].status.label, 'Duplicate IP');
  assert.equal(rows[2].status.tone, 'danger');
  assert.equal(rows[2].status.label, 'Invalid IP');
});

test('buildProvisionVmIpMap returns the edited per-vm map', () => {
  const rows = buildProvisionVmIpRows(vmPlan, {}, {
    vm_ips: ['192.168.2.61', '192.168.2.62', '192.168.2.63'],
  });

  assert.deepEqual(buildProvisionVmIpMap(rows), {
    'cp-1': '192.168.2.61',
    'worker-1': '192.168.2.62',
    'worker-2': '192.168.2.63',
  });
});
