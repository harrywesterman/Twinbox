export function securityHeadline(overview) {
  const labels = {
    action_needed: "Actie nodig binnen de gecontroleerde scope",
    review_needed: "Beoordeling nodig",
    no_open_findings_in_scope: "Geen open bevindingen binnen de gecontroleerde scope",
    insufficient_data: "Onvoldoende actuele gegevens",
  };
  return labels[overview?.status] || labels.insufficient_data;
}

export function assessmentLabel(status) {
  return (
    {
      affected: "van toepassing",
      needs_review: "te beoordelen",
      not_affected: "onderbouwd niet van toepassing",
      resolved: "opgelost in een nieuwe scan",
    }[status] || "onbekend"
  );
}
