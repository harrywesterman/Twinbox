function getKubernetesListItems(response) {
  const payload = response?.body ?? response;
  return Array.isArray(payload?.items) ? payload.items : [];
}

export { getKubernetesListItems };
