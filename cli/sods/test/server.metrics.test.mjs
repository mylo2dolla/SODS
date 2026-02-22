import assert from "node:assert/strict";
import test from "node:test";

import { SODSServer } from "../dist/server.js";

function makeServer(counterOverrides = {}) {
  const server = new SODSServer({
    port: 0,
    piLoggerBase: "http://logger.local:9101",
    publicDir: "./public",
    flashDir: "./public",
  });
  server.ingestor = {
    getCounters() {
      return {
        events_in: 11,
        events_bad_json: 2,
        events_out: 99,
        nodes_seen: 3,
        ...counterOverrides,
      };
    },
    getActiveBaseURL() {
      return "http://logger.local:9101";
    },
    getNodes() {
      return [];
    },
  };
  return server;
}

function requestJson(server, path) {
  let status = 0;
  let body = "";
  const req = {
    url: path,
    headers: { host: "localhost:9123" },
  };
  const res = {
    writeHead(code) {
      status = code;
    },
    end(chunk = "") {
      body = String(chunk);
    },
  };
  server.handleRequest(req, res);
  return { status, body: JSON.parse(body) };
}

test("metrics frames_out stays zero when no frames are emitted", () => {
  const server = makeServer({ events_out: 123 });
  server.frameEngine = { tick: () => [] };

  server.emitFrames();
  const payload = requestJson(server, "/metrics");

  assert.equal(payload.status, 200);
  assert.equal(payload.body.events_in, 11);
  assert.equal(payload.body.frames_out, 0);
});

test("metrics frames_out increments only by emitted frame count", () => {
  const server = makeServer({ events_out: 123 });
  const batches = [
    [{ id: "f1" }, { id: "f2" }],
    [],
    [{ id: "f3" }],
    [],
  ];
  server.frameEngine = {
    tick: () => batches.shift() ?? [],
  };

  server.emitFrames();
  server.emitFrames();
  server.emitFrames();
  let payload = requestJson(server, "/metrics");
  assert.equal(payload.body.frames_out, 3);

  server.emitFrames();
  payload = requestJson(server, "/metrics");
  assert.equal(payload.body.frames_out, 3);
});
