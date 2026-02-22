import assert from "node:assert/strict";
import test from "node:test";

import { Ingestor } from "../dist/ingest.js";

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function event(id, node = "node-a") {
  return {
    id,
    node_id: node,
    kind: "heartbeat",
    severity: "info",
    summary: "heartbeat",
    ts_ms: Date.now(),
    data: {},
  };
}

test("ingestor de-duplicates increasing numeric IDs across polls", async () => {
  const ingestor = new Ingestor("http://logger.local:9101");
  const emitted = [];
  ingestor.onEvent = (ev) => emitted.push(ev);
  ingestor.onError = (msg) => {
    throw new Error(msg);
  };

  const originalFetch = globalThis.fetch;
  const batches = [
    [event(1), event(2)],
    [event(2), event(3)],
  ];
  globalThis.fetch = async () => jsonResponse(200, batches.shift() ?? []);
  try {
    await ingestor.pollOnce();
    await ingestor.pollOnce();
  } finally {
    globalThis.fetch = originalFetch;
  }

  assert.deepEqual(
    emitted.map((ev) => ev.id),
    ["1", "2", "3"],
  );
  assert.equal(ingestor.getCounters().events_out, 3);
});

test("ingestor keeps bounded string-ID dedupe window and allows evicted IDs again", () => {
  const ingestor = new Ingestor("http://logger.local:9101");
  ingestor.seenMax = 2;

  const first = ingestor.filterFresh([event("a"), event("b")]);
  const second = ingestor.filterFresh([event("a")]);
  const third = ingestor.filterFresh([event("c"), event("d")]);
  const fourth = ingestor.filterFresh([event("a")]);

  assert.deepEqual(first.map((ev) => ev.id), ["a", "b"]);
  assert.equal(second.length, 0);
  assert.deepEqual(third.map((ev) => ev.id), ["c", "d"]);
  assert.deepEqual(fourth.map((ev) => ev.id), ["a"]);
});

test("ingestor falls back from /v1/events to /events and memorizes successful path per base URL", async () => {
  const ingestor = new Ingestor("http://logger.local:9101");
  ingestor.onEvent = () => {};
  ingestor.onError = (msg) => {
    throw new Error(msg);
  };

  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input) => {
    const url = new URL(String(input));
    calls.push(url.pathname);
    if (url.pathname === "/v1/events") {
      return jsonResponse(404, { error: "missing" });
    }
    if (url.pathname === "/events") {
      return jsonResponse(200, []);
    }
    throw new Error(`unexpected path ${url.pathname}`);
  };

  try {
    await ingestor.pollOnce();
    assert.deepEqual(calls, ["/v1/events", "/events"]);
    calls.length = 0;

    await ingestor.pollOnce();
    assert.deepEqual(calls, ["/events"]);
    assert.equal(ingestor.getActiveBaseURL(), "http://logger.local:9101");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("ingestor does not append aux fallback when explicit pi-logger URL is provided", () => {
  const prevAuxHost = process.env.AUX_HOST;
  const prevSodsAuxHost = process.env.SODS_AUX_HOST;
  const prevPiLoggerURL = process.env.PI_LOGGER_URL;
  const prevPiLogger = process.env.PI_LOGGER;
  try {
    delete process.env.AUX_HOST;
    delete process.env.SODS_AUX_HOST;
    process.env.PI_LOGGER_URL = "";
    process.env.PI_LOGGER = "";

    const ingestor = new Ingestor("http://192.168.8.114:9101");
    assert.deepEqual(ingestor.getBaseURLs(), ["http://192.168.8.114:9101"]);
  } finally {
    if (prevAuxHost === undefined) delete process.env.AUX_HOST;
    else process.env.AUX_HOST = prevAuxHost;
    if (prevSodsAuxHost === undefined) delete process.env.SODS_AUX_HOST;
    else process.env.SODS_AUX_HOST = prevSodsAuxHost;
    if (prevPiLoggerURL === undefined) delete process.env.PI_LOGGER_URL;
    else process.env.PI_LOGGER_URL = prevPiLoggerURL;
    if (prevPiLogger === undefined) delete process.env.PI_LOGGER;
    else process.env.PI_LOGGER = prevPiLogger;
  }
});
