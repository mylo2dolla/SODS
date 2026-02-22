import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { SODSServer } from "../dist/server.js";

function makeServer() {
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

function withEnv(overrides, run) {
  const previous = new Map();
  for (const [key, value] of Object.entries(overrides)) {
    previous.set(key, process.env[key]);
    if (value == null) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
  try {
    return run();
  } finally {
    for (const [key, value] of previous.entries()) {
      if (value == null) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  }
}

function request(server, { path: routePath, method = "GET", payload = null, headers = {} }) {
  let status = 0;
  let body = "";
  const handlers = {};
  const req = {
    url: routePath,
    method,
    headers: {
      host: "localhost:9123",
      ...headers,
    },
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
  if (method === "POST" || method === "PUT" || method === "PATCH" || method === "DELETE") {
    if (payload != null) {
      handlers.data?.(Buffer.from(JSON.stringify(payload)));
    }
    handlers.end?.();
  }

  let json = {};
  if (body.length) {
    try {
      json = JSON.parse(body);
    } catch {
      json = {};
    }
  }
  return { status, body, json };
}

test("app capabilities exposes expected matrix for ios and macos clients", () => {
  const server = makeServer();

  const ios = request(server, { path: "/api/app/capabilities?client=ios" });
  assert.equal(ios.status, 200);
  assert.equal(ios.json.ok, true);
  assert.equal(ios.json.client, "ios");
  assert.equal(ios.json.capabilities.scanner, true);
  assert.equal(ios.json.capabilities.spectrum, true);
  assert.equal(ios.json.capabilities.status, true);
  assert.equal(ios.json.capabilities.nodes, true);
  assert.equal(ios.json.capabilities.tools, true);
  assert.equal(ios.json.capabilities.runbooks, true);
  assert.equal(ios.json.capabilities.presets, true);
  assert.equal(ios.json.capabilities.eventsRecent, true);
  assert.equal(ios.json.capabilities.frameStream, true);
  assert.equal(ios.json.capabilities.localStationProcess, false);
  assert.equal(ios.json.capabilities.localFileReveal, false);
  assert.equal(ios.json.capabilities.localShellExecution, false);
  assert.equal(ios.json.capabilities.localUSBFlash, false);

  const macos = request(server, { path: "/api/app/capabilities?client=macos" });
  assert.equal(macos.status, 200);
  assert.equal(macos.json.ok, true);
  assert.equal(macos.json.client, "macos");
  assert.equal(macos.json.capabilities.scanner, true);
  assert.equal(macos.json.capabilities.spectrum, true);
  assert.equal(macos.json.capabilities.status, true);
  assert.equal(macos.json.capabilities.nodes, true);
  assert.equal(macos.json.capabilities.tools, true);
  assert.equal(macos.json.capabilities.runbooks, true);
  assert.equal(macos.json.capabilities.presets, true);
  assert.equal(macos.json.capabilities.eventsRecent, true);
  assert.equal(macos.json.capabilities.frameStream, true);
  assert.equal(macos.json.capabilities.localStationProcess, true);
  assert.equal(macos.json.capabilities.localFileReveal, true);
  assert.equal(macos.json.capabilities.localShellExecution, true);
  assert.equal(macos.json.capabilities.localUSBFlash, true);
});

test("app capabilities rejects unknown client type", () => {
  const server = makeServer();
  const response = request(server, { path: "/api/app/capabilities?client=android" });
  assert.equal(response.status, 400);
  assert.equal(response.json.ok, false);
});

test("mutating api routes require bearer token only when SODS_API_TOKEN is configured", () => {
  const tempRoot = path.join(os.tmpdir(), `sods-app-capabilities-${Date.now()}`);
  const knowledgePath = path.join(tempRoot, "facts.v1.json");
  const lockPath = path.join(tempRoot, "facts.v1.lock");

  withEnv({
    SODS_API_TOKEN: null,
    SODS_KNOWLEDGE_PATH: knowledgePath,
    SODS_KNOWLEDGE_LOCK_PATH: lockPath,
  }, () => {
    const server = makeServer();
    const response = request(server, {
      path: "/api/knowledge/upsert",
      method: "POST",
      payload: { upserts: [] },
    });
    assert.equal(response.status, 200);
    assert.equal(response.json.ok, true);
  });

  withEnv({
    SODS_API_TOKEN: "combo-token",
    SODS_KNOWLEDGE_PATH: knowledgePath,
    SODS_KNOWLEDGE_LOCK_PATH: lockPath,
  }, () => {
    const server = makeServer();
    let response = request(server, {
      path: "/api/knowledge/upsert",
      method: "POST",
      payload: { upserts: [] },
    });
    assert.equal(response.status, 401);
    assert.equal(response.json.ok, false);

    response = request(server, {
      path: "/api/knowledge/upsert",
      method: "POST",
      payload: { upserts: [] },
      headers: { authorization: "Bearer wrong-token" },
    });
    assert.equal(response.status, 401);
    assert.equal(response.json.ok, false);

    response = request(server, {
      path: "/api/knowledge/upsert",
      method: "POST",
      payload: { upserts: [] },
      headers: { authorization: "Bearer combo-token" },
    });
    assert.equal(response.status, 200);
    assert.equal(response.json.ok, true);

    response = request(server, {
      path: "/api/events/recent?limit=1",
    });
    assert.equal(response.status, 200);
  });
});
