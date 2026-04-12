import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildSuggestedProvisionInputs,
  mergeSuggestedProvisionDraft,
} from '../src/provision-defaults.js';

const stepInputs = [
  { id: 'name', default: 'twinbox-cluster' },
  { id: 'start_vmid', default: 200 },
  { id: 'vip_ip', default: '' },
  { id: 'node_prefix_length', default: '' },
  { id: 'gateway_ip', default: '' },
  { id: 'dns_servers', default: '1.1.1.1,8.8.8.8' },
  { id: 'dns_domain', default: 'localdomain' },
];

test('mergeSuggestedProvisionDraft refreshes auto-filled values when the suggestion changes', () => {
  const previousSuggested = buildSuggestedProvisionInputs({
    name_suggestion: 'twinbox-development',
    start_vmid: 119,
    vip_ip: '192.168.2.54',
    node_prefix_length: 24,
    gateway_ip: '192.168.2.1',
    dns_servers: ['1.1.1.1'],
    dns_domain: '',
  });

  const currentDraft = {
    name: 'twinbox-development',
    start_vmid: 119,
    vip_ip: '192.168.2.54',
    node_prefix_length: 24,
    gateway_ip: '192.168.2.1',
    dns_servers: '1.1.1.1',
    dns_domain: '',
  };

  const nextSuggested = {
    name_suggestion: 'twinbox-development',
    start_vmid: 119,
    vip_ip: '192.168.2.54',
    node_prefix_length: 24,
    gateway_ip: '192.168.2.1',
    dns_servers: ['1.1.1.1'],
    dns_domain: '',
  };

  const merged = mergeSuggestedProvisionDraft({
    currentDraft,
    previousSuggested,
    suggestionData: nextSuggested,
    stepInputs,
  });

  assert.equal(merged.start_vmid, 119);
});

test('mergeSuggestedProvisionDraft preserves manual overrides while updating untouched fields', () => {
  const previousSuggested = buildSuggestedProvisionInputs({
    name_suggestion: 'twinbox-development',
    start_vmid: 119,
    vip_ip: '192.168.2.54',
    node_prefix_length: 24,
    gateway_ip: '172.18.0.1',
    dns_servers: ['127.0.0.11'],
    dns_domain: 'localdomain',
  });

  const currentDraft = {
    name: 'twinbox-development',
    start_vmid: 119,
    vip_ip: '192.168.2.54',
    node_prefix_length: 24,
    gateway_ip: '192.168.2.1',
    dns_servers: '1.1.1.1',
    dns_domain: '',
  };

  const nextSuggested = {
    name_suggestion: 'twinbox-development',
    start_vmid: 119,
    vip_ip: '192.168.2.54',
    node_prefix_length: 24,
    gateway_ip: '192.168.2.1',
    dns_servers: ['1.1.1.1'],
    dns_domain: '',
  };

  const merged = mergeSuggestedProvisionDraft({
    currentDraft,
    previousSuggested,
    suggestionData: nextSuggested,
    stepInputs,
  });

  assert.equal(merged.gateway_ip, '192.168.2.1');
  assert.equal(merged.dns_servers, '1.1.1.1');
  assert.equal(merged.dns_domain, '');
});

test('mergeSuggestedProvisionDraft never overwrites dirty fields', () => {
  const merged = mergeSuggestedProvisionDraft({
    currentDraft: {
      dns_domain: '',
      gateway_ip: '192.168.2.1',
    },
    previousSuggested: {
      dns_domain: 'corp.internal',
      gateway_ip: '172.18.0.1',
    },
    suggestionData: {
      dns_domain: 'corp.internal',
      gateway_ip: '192.168.2.1',
    },
    stepInputs,
    dirtyFields: {
      dns_domain: true,
    },
  });

  assert.equal(merged.dns_domain, '');
  assert.equal(merged.gateway_ip, '192.168.2.1');
});

test('mergeSuggestedProvisionDraft replaces first-load defaults with a live suggestion', () => {
  const merged = mergeSuggestedProvisionDraft({
    currentDraft: {
      name: 'twinbox-cluster',
      start_vmid: 200,
      vip_ip: '',
      node_prefix_length: '',
      gateway_ip: '',
      dns_servers: '1.1.1.1,8.8.8.8',
      dns_domain: '',
    },
    previousSuggested: {},
    suggestionData: {
      name_suggestion: 'twinbox-lab',
      start_vmid: 212,
      vip_ip: '192.168.2.54',
      node_prefix_length: 24,
      gateway_ip: '192.168.2.1',
      dns_servers: ['1.1.1.1', '8.8.8.8'],
      dns_domain: '',
    },
    stepInputs,
  });

  assert.equal(merged.name, 'twinbox-lab');
  assert.equal(merged.vip_ip, '192.168.2.54');
  assert.equal(merged.gateway_ip, '192.168.2.1');
});
