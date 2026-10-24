import { useEffect, useState } from "react";

export default function SecurityPreflight() {
  const [report, setReport] = useState(null);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState(null);
  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/security/overview?scope=published", { signal: controller.signal })
      .then((response) => {
        if (!response.ok) throw new Error("Security check unavailable");
        return response.json();
      })
      .then(setReport)
      .catch((cause) => {
        if (cause.name !== "AbortError") setError(cause.message);
      });
    return () => controller.abort();
  }, []);
  async function showImage(key) {
    setError("");
    try {
      const response = await fetch(`/api/security/images/${encodeURIComponent(key)}`);
      if (!response.ok) throw new Error("Image details unavailable");
      setDetail((await response.json()).image);
    } catch (cause) {
      setError(cause.message);
    }
  }
  return (
    <section className="wizard-card security-preflight" aria-label="Beveiliging vóór installatie">
      <h2>Beveiliging vóór installatie</h2>
      <p>
        {error ||
          (report
            ? `${report.published.scannedImages} van ${report.published.expectedImages} eigen images gecontroleerd · ${report.published.needsReview} meldingen te beoordelen · ${report.published.actionNeeded} bevestigde acties.`
            : "Scanstatus laden…")}
      </p>
      {report?.published.sourceError && (
        <p role="alert">De recente controle is niet beschikbaar: {report.published.sourceError}</p>
      )}
      <p>
        Dit betreft gepubliceerde images. De beveiliging van een draaiende installatie is nog niet
        gemeten.
      </p>
      {report && (
        <button type="button" onClick={() => setExpanded(!expanded)} aria-expanded={expanded}>
          {expanded ? "Verberg details" : "Toon details"}
        </button>
      )}
      {expanded && (
        <ul>
          {report.images.map((image) => (
            <li key={image.key}>
              <button type="button" onClick={() => showImage(image.key)}>
                {image.logicalName}
              </button>
              :{image.needsReview} te beoordelen, {image.actionNeeded} acties
            </li>
          ))}
        </ul>
      )}
      {detail && (
        <div>
          <h3>{detail.logicalName}</h3>
          <p>
            {detail.platform} · {detail.digest}
          </p>
          <ul>
            {detail.findings.map((finding) => (
              <li key={finding.id}>
                {finding.originalSeverity}: {finding.vulnerabilityId} in {finding.target} —{" "}
                {finding.status}
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
