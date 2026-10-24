const TOPICS = [
  ["exposure", "Bereikbaarheid"],
  ["access", "Accounts en toegang"],
  ["detection", "Detectie"],
  ["recovery", "Back-ups en herstel"],
];

export function buildSecurityOverview(snapshot, sourceError = null, scope = "published") {
  const generated = snapshot?.generatedAt && Date.parse(snapshot.generatedAt);
  const stale =
    !generated || generated > Date.now() + 5 * 60_000 || Date.now() - generated > 36 * 60 * 60_000;
  const images = snapshot?.images || [];
  const complete = images.length === 7 && images.every((image) => image.scanStatus === "complete");
  const findings = images.flatMap((image) => image.findings || []);
  const open = findings.filter((finding) => finding.status === "affected");
  const review = findings.filter((finding) => finding.status === "needs_review");
  const status =
    sourceError || stale || !complete
      ? "insufficient_data"
      : open.length
        ? "action_needed"
        : review.length
          ? "review_needed"
          : "no_open_findings_in_scope";

  return {
    status,
    scope,
    published: {
      status,
      expectedImages: 7,
      scannedImages: images.length,
      findings: findings.length,
      actionNeeded: open.length,
      needsReview: review.length,
      notAffected: findings.filter((finding) => finding.status === "not_affected").length,
      generatedAt: snapshot?.generatedAt || null,
      stale,
      sourceError,
    },
    runtime: {
      status: "not_measured",
      explanation: "De draaiende image-digests zijn niet gecontroleerd.",
    },
    topics: TOPICS.map(([id, title]) => ({
      id,
      title,
      status: "not_measured",
      explanation: "Voor dit onderwerp is nog geen controle met actueel bewijs aangesloten.",
    })),
    images: images.map((image) => ({
      key: image.key,
      logicalName: image.logicalName,
      digest: image.digest,
      scannedAt: image.scannedAt,
      platform: image.platform,
      findings: image.findings?.length || 0,
      actionNeeded: image.findings?.filter((f) => f.status === "affected").length || 0,
      needsReview: image.findings?.filter((f) => f.status === "needs_review").length || 0,
    })),
  };
}
