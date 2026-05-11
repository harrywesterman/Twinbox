function coerceLogLine(entry) {
  if (typeof entry === "string") {
    return entry;
  }

  if (entry && typeof entry === "object" && typeof entry.line === "string") {
    return entry.line;
  }

  return "";
}

export function normalizeLogEntries(lines = []) {
  return (Array.isArray(lines) ? lines : []).map(coerceLogLine).filter((line) => line.length > 0);
}
