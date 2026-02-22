import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { SODSServer } from "../dist/server.js";

function makeServer(tmpDir) {
  process.env.SODS_KNOWLEDGE_PATH = path.join(tmpDir, "facts.v1.json");
  process.env.SODS_KNOWLEDGE_LOCK_PATH = path.join(tmpDir, "facts.v1.lock");
  const server = new SODSServer({
    port: 0,
    piLoggerBase: "http://logger.local:9101",
    publicDir: "./public",
    flashDir: "./public",
  });
  server.ingestor = {
    getCounters() {
      return {
        events_in: 0,
        events_bad_json: 0,
        events_out: 0,
        nodes_seen: 0,
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

function requestJson(server, { path, method = "GET", payload = null }) {
  let status = 0;
  let body = "";
  const handlers = {};
  const req = {
    url: path,
    method,
    headers: { host: "localhost:9123" },
    socket: { remoteAddress: "127.0.0.1" },
    on(event, handler) {
      handlers[event] = handler;
    },
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
  if (method === "POST") {
    if (payload != null) {
      handlers.data?.(Buffer.from(JSON.stringify(payload)));
    }
    handlers.end?.();
  }

  return {
    status,
    json: body ? JSON.parse(body) : {},
  };
}

test("knowledge upsert + resolve endpoint applies precedence and confidence gating", () => {
  const tmpDir = path.join(os.tmpdir(), `sods-knowledge-api-${Date.now()}`);
  const server = makeServer(tmpDir);

  let response = requestJson(server, {
    path: "/api/knowledge/upsert",
    method: "POST",
    payload: {
      upserts: [
        {
          entity_key: "ip:10.0.0.8",
          field: "ip",
          value: "10.0.0.8",
          source: "event.derived",
          confidence: 40,
          updated_at_ms: 1000,
        },
        {
          entity_key: "ip:10.0.0.8",
          field: "ip",
          value: "10.0.0.8",
          source: "scan.network.live",
          confidence: 55,
          updated_at_ms: 1001,
        },
        {
          entity_key: "ip:10.0.0.8",
          field: "display_label",
          value: "possible camera",
          source: "event.derived",
          confidence: 20,
          updated_at_ms: 1002,
        },
      ],
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.json.ok, true);
  assert.equal(response.json.upserted, 3);

  response = requestJson(server, {
    path: "/api/knowledge/resolve?keys=ip:10.0.0.8&fields=ip,display_label",
  });

  assert.equal(response.status, 200);
  assert.equal(response.json.by_field.ip.value, "10.0.0.8");
  assert.equal(response.json.by_field.ip.source, "scan.network.live");
  assert.equal(response.json.by_field.ip.auto_use, true);
  assert.equal(response.json.by_field.display_label.value, "possible camera");
  assert.equal(response.json.by_field.display_label.auto_use, false);
});

test("knowledge entity endpoint returns entity snapshot by key", () => {
  const tmpDir = path.join(os.tmpdir(), `sods-knowledge-entity-${Date.now()}`);
  const server = makeServer(tmpDir);

  requestJson(server, {
    path: "/api/knowledge/upsert",
    method: "POST",
    payload: {
      upserts: [
        {
          entity_key: "node:test-node",
          field: "node_id",
          value: "test-node",
          source: "station.registry",
          confidence: 90,
          updated_at_ms: Date.now(),
        },
      ],
    },
  });

  const response = requestJson(server, {
    path: "/api/knowledge/entity?key=node:test-node",
  });

  assert.equal(response.status, 200);
  assert.equal(response.json.entity.key, "node:test-node");
  assert.equal(response.json.entity.facts.node_id.value, "test-node");
});
