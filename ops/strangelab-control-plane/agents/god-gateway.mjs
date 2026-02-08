import express from "express";
import { Room } from "@livekit/rtc-node";
import { randomUUID } from "node:crypto";

const AUX_HOST = process.env.AUX_HOST || "192.168.8.114";
const LOGGER_HOST = process.env.LOGGER_HOST || "192.168.8.160";
const LIVEKIT_URL = process.env.LIVEKIT_URL || `ws://${AUX_HOST}:7880`;
const TOKEN_ENDPOINT = process.env.TOKEN_ENDPOINT || `http://${AUX_HOST}:9123/token`;
const ROOM_NAME = process.env.ROOM_NAME || "strangelab";
const IDENTITY = process.env.IDENTITY || "god-gateway";
const PORT = Number(process.env.PORT || 8099);
const HOST = process.env.HOST || "0.0.0.0";
const VAULT_INGEST_URL = process.env.VAULT_INGEST_URL || `http://${LOGGER_HOST}:8088/v1/ingest`;
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 3500);
const CONNECT_TIMEOUT_MS = Number(process.env.CONNECT_TIMEOUT_MS || 5000);
const PUBLISH_TIMEOUT_MS = Number(process.env.PUBLISH_TIMEOUT_MS || 3000);

let room = null;
let connecting = null;
const requestSeen = new Map();
const rateBuckets = new Map();

const RATE_LIMITS_PER_MIN = {
  panic: 5,
  snapshot: 30,
  maint: 20,
  scan: 6,
  build: 3,
  ritual: 10,
};

const LEGACY_OP_TO_ACTION = {
  panic: "panic.freeze.agents",
  whoami: "ritual.rollcall",
};

const ACTION_ALLOWLIST = new Set([
  "node.claim",
  "node.flash",
  "node.health.request",
  "panic.freeze.agents",
  "panic.lockdown.egress",
  "panic.isolate.node",
  "panic.kill.switch",
  "snapshot.now",
  "snapshot.services",
  "snapshot.net.routes",
  "snapshot.vault.verify",
  "maint.restart.service",
  "maint.status.service",
  "maint.logs.tail",
  "maint.disk.df",
  "maint.net.ping",
  "scan.lan.fast",
  "scan.lan.ports.top",
  "scan.ble.sweep",
  "scan.wifi.snapshot",
  "build.version.report",
  "build.flash.target",
  "build.rollback.target",
  "build.deploy.config",
  "ritual.rollcall",
  "ritual.heartbeat.burst",
  "ritual.quiet.mode",
  "ritual.wake.mode",
]);

function routeTopic(action) {
  if (action === "node.claim") return "ops.claim";
  if (action === "node.flash") return "ops.flash";
  if (action === "node.health.request") return "ops.health.request";
  if (action.startsWith("panic.")) return "ops.panic";
  if (action.startsWith("snapshot.")) return "ops.snapshot";
  if (action.startsWith("maint.")) return "ops.maint";
  if (action.startsWith("scan.")) return "ops.scan";
  if (action.startsWith("build.")) return "ops.build";
  if (action.startsWith("ritual.")) return "ops.ritual";
  return null;
}

function envelope(type, data) {
  return {
    type,
    src: IDENTITY,
    ts_ms: Date.now(),
    data,
  };
}

function gcMaps() {
  const now = Date.now();
  for (const [rid, ts] of requestSeen) {
    if (now - ts > 10 * 60_000) requestSeen.delete(rid);
  }
  for (const [cls, list] of rateBuckets) {
    rateBuckets.set(cls, list.filter((ts) => now - ts < 60_000));
  }
}

function actionClass(action) {
  return String(action || "").split(".")[0];
}

function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      setTimeout(() => reject(new Error(`${label} timeout after ${ms}ms`)), ms);
    }),
  ]);
}

function enforceRateLimit(action) {
  gcMaps();
  const cls = actionClass(action);
  const limit = RATE_LIMITS_PER_MIN[cls] || 20;
  const list = rateBuckets.get(cls) || [];
  if (list.length >= limit) {
    return { ok: false, reason: `rate limit exceeded for ${cls}` };
  }
  list.push(Date.now());
  rateBuckets.set(cls, list);
  return { ok: true, reason: "" };
}

async function vaultIngest(event) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  const r = await fetch(VAULT_INGEST_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(event),
    signal: controller.signal,
  }).finally(() => {
    clearTimeout(timer);
  });
  if (!r.ok) {
    const t = await r.text().catch(() => "");
    throw new Error(`vault ingest failed: ${r.status} ${t}`);
  }
}

async function getToken() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  const r = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identity: IDENTITY, room: ROOM_NAME }),
    signal: controller.signal,
  }).finally(() => {
    clearTimeout(timer);
  });
  const j = await r.json();
  if (!j.ok) throw new Error(j.error || "token endpoint failed");
  return j.token;
}

async function connectRoom() {
  if (room && room.state === "connected") return room;
  if (connecting) return connecting;

  connecting = (async () => {
    const token = await getToken();
    const nextRoom = new Room();
    nextRoom.on("disconnected", () => {
      room = null;
    });
    await withTimeout(nextRoom.connect(LIVEKIT_URL, token), CONNECT_TIMEOUT_MS, "livekit connect");
    room = nextRoom;
    return nextRoom;
  })();

  try {
    return await connecting;
  } finally {
    connecting = null;
  }
}

function normalizeRequest(input) {
  const legacyOp = String(input?.op || "");
  const action = String(input?.action || LEGACY_OP_TO_ACTION[legacyOp] || "");
  return {
    action,
    scope: String(input?.scope || "all"),
    target: input?.target ?? input?.node_id ?? null,
    request_id: String(input?.request_id || randomUUID()),
    reason: String(input?.reason || "manual"),
    ts_ms: Number(input?.ts_ms || Date.now()),
    args: typeof input?.args === "object" && input.args ? input.args : {},
    op: legacyOp || undefined,
  };
}

async function publish(topic, payload) {
  const liveRoom = await connectRoom();
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  await withTimeout(
    liveRoom.localParticipant.publishData(bytes, { reliable: true, topic }),
    PUBLISH_TIMEOUT_MS,
    `publish ${topic}`
  );
}

async function dispatchGod(input) {
  const started = Date.now();
  const request = normalizeRequest(input);

  await vaultIngest(envelope("router.intent", { request }));

  if (requestSeen.has(request.request_id)) {
    await vaultIngest(envelope("router.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: "duplicate request_id",
    }));
    throw new Error("duplicate request_id");
  }
  requestSeen.set(request.request_id, Date.now());

  if (!request.action || !ACTION_ALLOWLIST.has(request.action)) {
    await vaultIngest(envelope("router.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: "action missing or not allowlisted",
    }));
    throw new Error("action missing or not allowlisted");
  }

  const rl = enforceRateLimit(request.action);
  if (!rl.ok) {
    await vaultIngest(envelope("router.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: rl.reason,
    }));
    throw new Error(rl.reason);
  }

  const routedTopic = routeTopic(request.action);
  if (!routedTopic) {
    await vaultIngest(envelope("router.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: "unable to route action topic",
    }));
    throw new Error("unable to route action topic");
  }

  // Vault-first intent log, fail closed if unavailable.
  await vaultIngest(envelope("control.god_button.intent", {
    request,
  }));

  await publish("god.button", request);
  await publish(routedTopic, request);

  await vaultIngest(envelope("router.route.result", {
    request_id: request.request_id,
    action: request.action,
    routed_topic: routedTopic,
    ok: true,
  }));

  const result = {
    ok: true,
    handled_by: IDENTITY,
    duration_ms: Date.now() - started,
    result_summary: `dispatched to god.button + ${routedTopic}`,
    routed_topic: routedTopic,
  };

  await vaultIngest(envelope("control.god_button.result", {
    request_id: request.request_id,
    action: request.action,
    result,
  }));

  return { request, result };
}

const app = express();
app.use(express.json());

app.get("/health", async (_req, res) => {
  try {
    await connectRoom();
    res.json({ ok: true, room: ROOM_NAME, identity: IDENTITY, livekit_url: LIVEKIT_URL });
  } catch (e) {
    res.status(503).json({ ok: false, error: String(e?.message || e) });
  }
});

app.post("/god", async (req, res) => {
  try {
    const output = await dispatchGod(req.body ?? {});
    res.json({ ok: true, ...output });
  } catch (e) {
    console.error(`god dispatch failed: ${String(e?.message || e)}`);
    res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});

app.listen(PORT, HOST, async () => {
  console.log(`god gateway on http://${HOST}:${PORT}/god`);
  try {
    await connectRoom();
    console.log("god gateway connected to LiveKit");
  } catch (e) {
    console.error(`initial LiveKit connect failed: ${String(e?.message || e)}`);
  }
});
