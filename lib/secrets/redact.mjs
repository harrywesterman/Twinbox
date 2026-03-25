function uniqueStrings(values) {
  return [...new Set(values.filter((value) => typeof value === "string" && value.length > 0))];
}

export function buildRedactor(values = []) {
  const needles = uniqueStrings(values).sort((left, right) => right.length - left.length);
  if (needles.length === 0) {
    return (text) => String(text ?? "");
  }

  return (text) => {
    let output = String(text ?? "");
    for (const needle of needles) {
      output = output.split(needle).join("[REDACTED]");
    }
    return output;
  };
}
