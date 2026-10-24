import { useEffect, useState } from "react";
import { assessmentLabel, securityHeadline } from "./admin-security-model.js";

export default function AdminSecurityPage() {
  const [overview, setOverview] = useState(null);
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState("");
  const [findingFilter, setFindingFilter] = useState("open");

  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/admin/security", { signal: controller.signal })
      .then((response) => {
        if (!response.ok) throw new Error("Beveiligingsoverzicht niet bereikbaar.");
        return response.json();
      })
      .then(setOverview)
      .catch((cause) => {
        if (cause.name !== "AbortError") setError(cause.message);
      });
    return () => controller.abort();
  }, []);

  async function showImage(key) {
    setError("");
    try {
      const response = await fetch(`/api/admin/security/images/${encodeURIComponent(key)}`);
      if (!response.ok) throw new Error("Details niet bereikbaar.");
      setDetail((await response.json()).image);
    } catch (cause) {
      setError(cause.message);
    }
  }

  return (
    <main className="security-overview">
      <header className="security-overview-hero">
        <p className="security-eyebrow">TWINBOX / BEVEILIGING</p>
        <h1>Beveiligingsoverzicht</h1>
        <p>Wat is gecontroleerd, wat vraagt aandacht en wat weten we nog niet?</p>
        <strong role="status">
          {error || (overview ? securityHeadline(overview) : "Gegevens laden…")}
        </strong>
      </header>
      {overview && (
        <>
          <section aria-label="Meetdekking" className="security-overview-section">
            <h2>Gepubliceerde software</h2>
            <p>
              {overview.published.scannedImages} van {overview.published.expectedImages} eigen
              images gecontroleerd.
              {overview.published.generatedAt &&
                ` Laatste rapport: ${new Date(overview.published.generatedAt).toLocaleString("nl-NL")}.`}
            </p>
            <p>
              {overview.published.actionNeeded} bevestigde bevindingen,{" "}
              {overview.published.needsReview} te beoordelen,
              {overview.published.notAffected} onderbouwd niet van toepassing.
            </p>
            {overview.published.sourceError && (
              <p role="alert">Bronfout: {overview.published.sourceError}</p>
            )}
            <ul className="security-image-list">
              {overview.images.map((image) => (
                <li key={image.key}>
                  <button type="button" onClick={() => showImage(image.key)}>
                    <span>{image.logicalName}</span>
                    <span>
                      {image.needsReview} te beoordelen · {image.actionNeeded} acties
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
          <section className="security-overview-section">
            <h2>Draaiende installatie</h2>
            <p>
              {overview.runtime.explanation} Gepubliceerde images bewijzen niet welke versie actief
              is.
            </p>
          </section>
          <section className="security-overview-section">
            <h2>Andere beveiligingscontroles</h2>
            <ul>
              {overview.topics.map((topic) => (
                <li key={topic.id}>
                  <strong>{topic.title}</strong>: {topic.explanation}
                </li>
              ))}
            </ul>
          </section>
        </>
      )}
      {detail && (
        <section className="security-overview-section" aria-label="Image-details">
          <button type="button" onClick={() => setDetail(null)}>
            Sluit details
          </button>
          <h2>{detail.logicalName}</h2>
          <p>
            Digest: <code>{detail.digest}</code> · Platform: {detail.platform}
          </p>
          <label>
            Toon meldingen
            <select
              value={findingFilter}
              onChange={(event) => setFindingFilter(event.target.value)}
            >
              <option value="open">Actie en beoordeling</option>
              <option value="not_affected">Onderbouwd niet van toepassing</option>
              <option value="all">Alle meldingen</option>
            </select>
          </label>
          <ul>
            {detail.findings
              .filter(
                (finding) =>
                  findingFilter === "all" ||
                  (findingFilter === "open"
                    ? finding.status !== "not_affected"
                    : finding.status === "not_affected")
              )
              .map((finding) => (
                <li key={finding.id}>
                  <strong>
                    {finding.originalSeverity} · {assessmentLabel(finding.status)}
                  </strong>{" "}
                  — {finding.assessmentReason || finding.reason}
                  <details>
                    <summary>Technische gegevens</summary>
                    <p>
                      {finding.target} · {finding.packageName} {finding.installedVersion} ·{" "}
                      {finding.vulnerabilityId}
                    </p>
                    {finding.evidenceRefs?.map((reference) => (
                      <a key={reference.url} href={reference.url} target="_blank" rel="noreferrer">
                        Bron
                      </a>
                    ))}
                  </details>
                </li>
              ))}
          </ul>
        </section>
      )}
    </main>
  );
}
