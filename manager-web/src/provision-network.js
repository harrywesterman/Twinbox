function normalizeIpv4(value) {
  return String(value || '').trim();
}

export function isValidIpv4(value) {
  const candidate = normalizeIpv4(value);
  if (!candidate) {
    return false;
  }

  const parts = candidate.split('.');
  if (parts.length !== 4) {
    return false;
  }

  return parts.every((part) => {
    if (!/^\d+$/.test(part)) {
      return false;
    }
    if (part.length > 1 && part.startsWith('0')) {
      return false;
    }
    const octet = Number(part);
    return Number.isInteger(octet) && octet >= 0 && octet <= 255;
  });
}

export function buildProvisionVmIpRows(vmPlan = [], currentValues = {}, suggestionSnapshot = {}, availabilityMap = {}) {
  const plan = Array.isArray(vmPlan) ? vmPlan : [];
  const currentVmIpMap = currentValues && typeof currentValues.vm_ip_map === 'object' && !Array.isArray(currentValues.vm_ip_map)
    ? currentValues.vm_ip_map
    : {};
  const suggestedVmIps = Array.isArray(suggestionSnapshot?.vm_ips) ? suggestionSnapshot.vm_ips : [];

  const rows = plan.map((vm, index) => {
    const suggestedIp = normalizeIpv4(suggestedVmIps[index] || '');
    const value = normalizeIpv4(currentVmIpMap[vm.name] ?? suggestedIp);
    return {
      ...vm,
      suggestedIp,
      value,
    };
  });

  const duplicateCounts = rows.reduce((accumulator, row) => {
    const normalized = normalizeIpv4(row.value);
    if (!isValidIpv4(normalized)) {
      return accumulator;
    }
    accumulator[normalized] = (accumulator[normalized] || 0) + 1;
    return accumulator;
  }, {});

  return rows.map((row) => {
    const isValid = isValidIpv4(row.value);
    const isDuplicate = isValid && duplicateCounts[row.value] > 1;
    const isSuggested = Boolean(isValid && row.suggestedIp && row.value === row.suggestedIp);

    let status = {
      tone: 'warning',
      label: 'Locally edited',
      icon: '◌',
    };

    if (!isValid) {
      status = {
        tone: 'danger',
        label: 'Invalid IP',
        icon: '!',
      };
    } else if (availabilityMap && Object.prototype.hasOwnProperty.call(availabilityMap, row.value)) {
      const isFree = Boolean(availabilityMap[row.value]);
      status = {
        tone: isFree ? 'success' : 'danger',
        label: isFree ? 'Checked free' : 'Already in use',
        icon: isFree ? '✓' : '!',
      };
    } else if (isDuplicate) {
      status = {
        tone: 'danger',
        label: 'Duplicate IP',
        icon: '!',
      };
    } else if (isSuggested) {
      status = {
        tone: 'success',
        label: 'Verified free',
        icon: '✓',
      };
    }

    return {
      ...row,
      isValid,
      isDuplicate,
      isSuggested,
      status,
    };
  });
}

export function buildProvisionVmIpMap(vmIpRows = []) {
  return vmIpRows.reduce((accumulator, row) => {
    if (row?.name) {
      accumulator[row.name] = normalizeIpv4(row.value);
    }
    return accumulator;
  }, {});
}

export function validateProvisionVmIpRows(vmIpRows = []) {
  const rows = Array.isArray(vmIpRows) ? vmIpRows : [];
  const invalidRows = rows.filter((row) => !row.isValid);
  const duplicateRows = rows.filter((row) => row.isDuplicate);
  const allValid = invalidRows.length === 0 && duplicateRows.length === 0 && rows.every((row) => normalizeIpv4(row.value));

  if (invalidRows.length > 0) {
    return {
      ok: false,
      error: `Invalid IP address for ${invalidRows[0].label || invalidRows[0].name}`,
      invalidRows,
      duplicateRows,
    };
  }

  if (duplicateRows.length > 0) {
    return {
      ok: false,
      error: `Duplicate IP address ${duplicateRows[0].value} is used more than once`,
      invalidRows,
      duplicateRows,
    };
  }

  return {
    ok: allValid,
    error: allValid ? '' : 'One or more VM IP addresses are missing',
    invalidRows,
    duplicateRows,
  };
}
