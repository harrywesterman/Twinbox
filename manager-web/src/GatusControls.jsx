export default function GatusControls({ step, busy, onTest }) {
  const outputs = step?.state?.outputs || {};
  if (step?.id === "configure-gatus-notifications") {
    return (
      <section className="wizard-card" aria-label="Gatus notification tests">
        <p>
          Opgeslagen velden: {(outputs.credentials_set || []).join(", ") || "nog geen"}. Laat
          geheime velden leeg om de opgeslagen waarde te behouden.
        </p>
        <button className="button" type="button" disabled={busy} onClick={onTest}>
          Testmelding sturen
        </button>
        {outputs.test && <p>{outputs.test.provider}: testmelding verzonden.</p>}
      </section>
    );
  }
  if (step?.id !== "install-gatus" || !outputs.status_url) return null;
  return (
    <section className="wizard-card" aria-label="Gatus synchronisation status">
      <a href={outputs.status_url} target="_blank" rel="noopener noreferrer">
        Open statuspagina
      </a>
      <p>Laatste synchronisatie: {outputs.last_success_at || "onbekend"}</p>
      {[...(outputs.warnings || []), outputs.sync_warning].filter(Boolean).map((warning) => (
        <p key={warning} role="status">
          {warning}
        </p>
      ))}
    </section>
  );
}
