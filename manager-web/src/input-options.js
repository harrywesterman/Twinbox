export function getInputOptions(input, value) {
  const options = Array.isArray(input?.options) ? input.options : [];
  const currentValue = String(value ?? "").trim();

  if (
    !currentValue ||
    options.some((option) => String(option?.value ?? "").trim() === currentValue)
  ) {
    return options;
  }

  return [...options, { label: `${currentValue} (saved value)`, value: currentValue }];
}
