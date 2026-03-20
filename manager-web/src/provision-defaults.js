const SUGGESTED_FIELD_IDS = [
  'name',
  'start_vmid',
  'vip_ip',
  'start_ip',
  'node_prefix_length',
  'gateway_ip',
  'dns_servers',
  'dns_domain',
];

export function buildSuggestedProvisionInputs(data = {}) {
  return {
    name: data.name_suggestion ?? undefined,
    start_vmid: data.start_vmid ?? undefined,
    vip_ip: data.vip_ip ?? undefined,
    start_ip: data.start_ip ?? undefined,
    node_prefix_length: data.node_prefix_length ?? undefined,
    gateway_ip: data.gateway_ip ?? undefined,
    dns_servers: Array.isArray(data.dns_servers) ? data.dns_servers.join(', ') : (data.dns_servers ?? undefined),
    dns_domain: typeof data.dns_domain === 'string' ? data.dns_domain : undefined,
  };
}

export function mergeSuggestedProvisionDraft({
  currentDraft = {},
  previousSuggested = {},
  suggestionData = {},
  stepInputs = [],
  dirtyFields = {},
}) {
  const nextSuggested = buildSuggestedProvisionInputs(suggestionData);
  const defaults = new Map((stepInputs || []).map((input) => [input.id, input.default]));
  const merged = { ...currentDraft };

  for (const fieldId of SUGGESTED_FIELD_IDS) {
    if (dirtyFields[fieldId]) {
      continue;
    }

    const suggestedValue = nextSuggested[fieldId];
    if (suggestedValue === undefined) {
      continue;
    }

    const currentValue = currentDraft[fieldId];
    const defaultValue = defaults.get(fieldId);
    const previousValue = previousSuggested[fieldId];
    if (currentValue === undefined || currentValue === defaultValue || currentValue === previousValue) {
      merged[fieldId] = suggestedValue;
    }
  }

  return merged;
}
