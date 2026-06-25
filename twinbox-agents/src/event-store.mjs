import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

function createEventStore(dataDir) {
  const effectiveDataDir = process.env.AGENT_DATA_DIR || dataDir || "/data";
  const eventsDir = join(effectiveDataDir, "events");
  const eventsFile = join(eventsDir, "events.jsonl");
  let sequenceCounter = 0;

  function ensureDir() {
    if (!existsSync(eventsDir)) {
      mkdirSync(eventsDir, { recursive: true });
    }
  }

  ensureDir();

  function appendEvent(event) {
    ensureDir();
    sequenceCounter += 1;
    const entry = {
      _seq: sequenceCounter,
      id: event.id || randomUUID(),
      timestamp: event.timestamp || new Date().toISOString(),
      agentId: event.agentId || null,
      workOrderId: event.workOrderId || null,
      type: event.type || "status",
      severity: event.severity || "info",
      title: event.title || "",
      message: event.message || "",
      metadata: event.metadata || {},
    };

    const line = JSON.stringify(entry) + "\n";
    const tmpFile = eventsFile + ".tmp";
    const existing = existsSync(eventsFile) ? readFileSync(eventsFile, "utf-8") : "";
    writeFileSync(tmpFile, existing + line, "utf-8");
    renameSync(tmpFile, eventsFile);
    return entry;
  }

  function listEvents({ sinceId, limit } = {}) {
    if (!existsSync(eventsFile)) {
      return [];
    }
    const effectiveLimit = Math.min(limit || 100, 500);
    const content = readFileSync(eventsFile, "utf-8").trim();
    if (!content) {
      return [];
    }

    const lines = content.split("\n");
    const events = [];
    let foundSince = !sinceId;

    for (const line of lines) {
      try {
        const event = JSON.parse(line);
        if (!foundSince && event.id === sinceId) {
          foundSince = true;
          continue;
        }
        if (foundSince) {
          events.push(event);
        }
      } catch {
        // skip malformed lines
      }
    }

    events.sort((a, b) => {
      const da = new Date(a.timestamp || 0).getTime();
      const db = new Date(b.timestamp || 0).getTime();
      if (da !== db) return db - da;
      return (b._seq || 0) - (a._seq || 0);
    });

    return events.slice(0, effectiveLimit);
  }

  return {
    appendEvent,
    listEvents,
  };
}

export { createEventStore };
