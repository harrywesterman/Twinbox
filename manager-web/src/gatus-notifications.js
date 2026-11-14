export function gatusTestInputs(draft = {}) {
  return {
    test_only: true,
    test_provider: ["telegram", "ntfy", "pushover"].includes(draft.test_provider)
      ? draft.test_provider
      : "telegram",
  };
}
