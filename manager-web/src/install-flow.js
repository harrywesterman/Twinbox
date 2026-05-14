export function normalizeJobResult(result) {
  if (!result || typeof result !== "object") {
    return null;
  }

  if (result.job && typeof result.job === "object") {
    return result.job;
  }

  return result;
}

export function buildQueueFailureNotice(stepTitle) {
  return `Could not queue ${stepTitle}.`;
}

export function buildInstallRefreshFailureNotice(stepTitle) {
  return `${stepTitle} completed successfully, but Twinbox could not refresh the wizard state.`;
}
