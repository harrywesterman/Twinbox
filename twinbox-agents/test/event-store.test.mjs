import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { createEventStore } from "../src/event-store.mjs";

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "event-store-test-"));
}

test("event-store appends and lists events", () => {
  const dataDir = tempDir();
  const store = createEventStore(dataDir);

  const event = store.appendEvent({
    agentId: "olivia-ops",
    workOrderId: "wo_001",
    type: "status",
    severity: "info",
    title: "Test event",
    message: "Testing",
  });

  assert.ok(event.id);
  assert.ok(event.timestamp);

  const events = store.listEvents({});
  assert.equal(events.length, 1);
  assert.equal(events[0].agentId, "olivia-ops");
});

test("event-store respects limit", () => {
  const dataDir = tempDir();
  const store = createEventStore(dataDir);

  for (let i = 0; i < 10; i++) {
    store.appendEvent({
      agentId: "test",
      type: "status",
      severity: "info",
      title: `Event ${i}`,
    });
  }

  const limited = store.listEvents({ limit: 3 });
  assert.equal(limited.length, 3);
});

test("event-store list returns newest first", () => {
  const dataDir = tempDir();
  const store = createEventStore(dataDir);

  store.appendEvent({
    agentId: "test",
    type: "status",
    severity: "info",
    title: "First",
  });

  store.appendEvent({
    agentId: "test",
    type: "status",
    severity: "info",
    title: "Second",
  });

  const events = store.listEvents({});
  assert.equal(events[0].title, "Second");
  assert.equal(events[1].title, "First");
  // The _seq ensures stable ordering for same-timestamp events
  assert.ok(events[0]._seq > events[1]._seq);
});

test("event-store supports sinceId", () => {
  const dataDir = tempDir();
  const store = createEventStore(dataDir);

  const first = store.appendEvent({
    agentId: "test",
    type: "status",
    severity: "info",
    title: "First",
  });

  store.appendEvent({
    agentId: "test",
    type: "status",
    severity: "info",
    title: "Second",
  });

  const sinceEvents = store.listEvents({ sinceId: first.id });
  assert.equal(sinceEvents.length, 1);
  assert.equal(sinceEvents[0].title, "Second");
});

test("event-store defaults limit to 100", () => {
  const dataDir = tempDir();
  const store = createEventStore(dataDir);

  for (let i = 0; i < 50; i++) {
    store.appendEvent({
      agentId: "test",
      type: "status",
      severity: "info",
      title: `Event ${i}`,
    });
  }

  const events = store.listEvents({});
  assert.equal(events.length, 50);
});

test("event-store auto-creates data directory", () => {
  const dataDir = tempDir();
  fs.rmSync(dataDir, { recursive: true, force: true });
  createEventStore(dataDir);
  assert.ok(fs.existsSync(path.join(dataDir, "events")));
});
