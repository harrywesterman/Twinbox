export function isInputVisible(input, answers = {}) {
  const condition = input?.visible_when;
  if (!condition) return true;
  return String(answers?.[condition.input] ?? "") === String(condition.equals ?? "");
}

export function omitSensitiveAnswers(catalog, answers = {}) {
  const sensitiveByStep = new Map(
    (catalog?.categories || []).flatMap((category) =>
      (category.steps || []).map((step) => [
        step.id,
        new Set((step.inputs || []).filter((input) => input.sensitive).map((input) => input.id)),
      ])
    )
  );
  return Object.fromEntries(
    Object.entries(answers || {}).map(([stepId, stepAnswers]) => {
      const sensitive = sensitiveByStep.get(stepId) || new Set();
      return [
        stepId,
        Object.fromEntries(
          Object.entries(stepAnswers || {}).filter(([inputId]) => !sensitive.has(inputId))
        ),
      ];
    })
  );
}
