export function gatusTestInputs(draft = {}) {
  return {
    test_only: true,
    test_provider: ["telegram", "ntfy", "pushover"].includes(draft.test_provider)
      ? draft.test_provider
      : "telegram",
  };
}

export function visibleGatusInputs(step) {
  return (step?.inputs || []).filter(
    (input) => step.id !== "configure-gatus-notifications" || input.id !== "test_only"
  );
}
