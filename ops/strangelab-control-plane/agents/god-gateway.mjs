import express from "express";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { resolve as resolvePath } from "node:path";

const AUX_HOST = process.env.AUX_HOST || "pi-aux.local";
const LOGGER_HOST = process.env.LOGGER_HOST || "pi-logger.local";
const PORT = Number(process.env.PORT || 8099);
const HOST = process.env.HOST || "0.0.0.0";
const IDENTITY = process.env.IDENTITY || "god-gateway";

const VAULT_INGEST_URL = process.env.VAULT_INGEST_URL || `http://${LOGGER_HOST}:8088/v1/ingest`;
const FETCH_TIMEOUT_MS = Number(process.env.FETCH_TIMEOUT_MS || 8000);
const FETCH_RETRIES = Math.max(0, Number(process.env.GOD_FETCH_RETRIES || 2));

const FED_GATEWAY_URL = (process.env.FED_GATEWAY_URL || "http://127.0.0.1:9777").replace(/\/$/, "");
const FED_GATEWAY_HEALTH_URL = process.env.FED_GATEWAY_HEALTH_URL || `${FED_GATEWAY_URL}/v1/health`;
const FED_GATEWAY_BEARER = (process.env.FED_GATEWAY_BEARER || "").trim();
const FED_TARGETS_FILE = process.env.FED_TARGETS_FILE || "/opt/strangelab/federation-targets.json";
const FED_DISPATCH_TIMEOUT_MS = Number(process.env.FED_DISPATCH_TIMEOUT_MS || 10000);
const FED_DISPATCH_RETRIES = Math.max(0, Number(process.env.FED_DISPATCH_RETRIES || 2));
const FED_SYNC_CACHE_MS = Math.max(5000, Number(process.env.FED_SYNC_CACHE_MS || 20000));
const FED_TUNNEL_HOST = process.env.FED_TUNNEL_HOST || "mac16";
const FED_TUNNEL_REMOTE_PORT = Number(process.env.FED_TUNNEL_REMOTE_PORT || 9777);

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

const BUILTIN_FEDERATION_TARGETS = {
  schema_version: "2026-02-13",
  defaults: {
    dispatch_op: "dispatch.intent",
    fallback_to_first_agent: true,
    agent_selector: {
      name_regex: "(sods|strange|ops|control|gateway)",
    },
    intent_template: "sods.action ${action} scope=${scope} target=${target} request_id=${request_id} reason=${reason} args=${args_json}",
  },
  actions: Object.fromEntries(Array.from(ACTION_ALLOWLIST).map((action) => [action, {}])),
};

const targetsCache = {
  path: "",
  mtimeMs: 0,
  loaded: null,
  loadError: "",
  warnLogged: false,
};

const snapshotCache = {
  fetchedAtMs: 0,
  snapshot: null,
};

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

function isDryRun(request) {
  if (!request || typeof request !== "object") return false;
  const args = request.args;
  if (!args || typeof args !== "object") return false;
  if (args.dry_run === true || args.dryRun === true) return true;
  if (typeof args.dry_run === "string") return args.dry_run.toLowerCase() === "true";
  if (typeof args.dryRun === "string") return args.dryRun.toLowerCase() === "true";
  return false;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isTransientError(error) {
  if (!error) return false;
  if (error.transient === true) return true;
  const message = String(error?.message || error).toLowerCase();
  return message.includes("timed out")
    || message.includes("timeout")
    || message.includes("aborted")
    || message.includes("fetch failed")
    || message.includes("connection reset")
    || message.includes("connection refused")
    || message.includes("econnreset")
    || message.includes("econnrefused")
    || message.includes("eai_again")
    || message.includes("http 503")
    || message.includes("http 502")
    || message.includes("http 429")
    || message.includes("http 408");
}

async function retryTransient(label, attempts, fn) {
  let lastError = null;
  for (let attempt = 0; attempt <= attempts; attempt += 1) {
    try {
      return await fn(attempt);
    } catch (error) {
      lastError = error;
      if (attempt >= attempts || !isTransientError(error)) {
        throw error;
      }
      console.warn(`${label} transient failure; retry ${attempt + 1}/${attempts}: ${String(error?.message || error)}`);
      await sleep(150 * (attempt + 1));
    }
  }
  throw lastError || new Error(`${label} failed`);
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

function withTimeoutSignal(ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  return { controller, timer };
}

function parsedJSON(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function fetchText(url, init = {}, timeoutMs = FETCH_TIMEOUT_MS) {
  const { controller, timer } = withTimeoutSignal(timeoutMs);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    const text = await response.text();
    return { response, text };
  } finally {
    clearTimeout(timer);
  }
}

async function vaultIngest(event) {
  await retryTransient("vault ingest", FETCH_RETRIES, async () => {
    const { response, text } = await fetchText(
      VAULT_INGEST_URL,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(event),
      },
      FETCH_TIMEOUT_MS,
    );
    if (!response.ok) {
      const err = new Error(`vault ingest failed: HTTP ${response.status} ${text}`);
      if (response.status >= 500 || response.status === 429 || response.status === 408) err.transient = true;
      throw err;
    }
  });
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

function normalizeTargetsData(raw, sourcePath) {
  if (!raw || typeof raw !== "object" || !raw.actions || typeof raw.actions !== "object") {
    throw new Error(`invalid federation targets schema in ${sourcePath}`);
  }
  const defaults = raw.defaults && typeof raw.defaults === "object" ? raw.defaults : {};
  return {
    schema_version: String(raw.schema_version || "unknown"),
    defaults,
    actions: raw.actions,
  };
}

function loadFederationTargets() {
  const resolvedPath = resolvePath(FED_TARGETS_FILE);
  if (!existsSync(resolvedPath)) {
    if (!targetsCache.warnLogged) {
      console.warn(`federation targets missing at ${resolvedPath}; using builtin defaults`);
      targetsCache.warnLogged = true;
    }
    targetsCache.path = resolvedPath;
    targetsCache.loaded = BUILTIN_FEDERATION_TARGETS;
    targetsCache.loadError = "";
    return targetsCache.loaded;
  }

  const stats = statSync(resolvedPath);
  const mtimeMs = stats.mtimeMs || 0;
  if (targetsCache.loaded && targetsCache.path === resolvedPath && targetsCache.mtimeMs === mtimeMs) {
    return targetsCache.loaded;
  }

  const parsed = parsedJSON(readFileSync(resolvedPath, "utf8"));
  const normalized = normalizeTargetsData(parsed, resolvedPath);
  targetsCache.path = resolvedPath;
  targetsCache.mtimeMs = mtimeMs;
  targetsCache.loaded = normalized;
  targetsCache.loadError = "";
  return normalized;
}

async function gatewayPost(op, payload, requestId, timeoutMs = FED_DISPATCH_TIMEOUT_MS) {
  const envelopePayload = {
    v: 1,
    msgId: requestId,
    tsMs: Date.now(),
    nonce: randomUUID().replace(/-/g, ""),
    traceId: requestId,
    deviceId: IDENTITY,
    tokenId: null,
    op,
    payload,
  };

  const headers = {
    "content-type": "application/json",
    accept: "application/json",
  };
  if (FED_GATEWAY_BEARER) {
    headers.authorization = `Bearer ${FED_GATEWAY_BEARER}`;
  }

  const { response, text } = await fetchText(
    `${FED_GATEWAY_URL}/v1/gateway`,
    {
      method: "POST",
      headers,
      body: JSON.stringify(envelopePayload),
    },
    timeoutMs,
  );

  const body = parsedJSON(text);
  if (!response.ok) {
    const err = new Error(`gateway ${op} failed: HTTP ${response.status} ${text}`);
    if (response.status >= 500 || response.status === 429 || response.status === 408) err.transient = true;
    throw err;
  }
  if (!body || body.ok !== true) {
    const message = body?.error?.message || body?.error || text || "gateway response not ok";
    const err = new Error(`gateway ${op} failed: ${message}`);
    if (typeof message === "string" && /timeout|temporar|rate|busy|retry|network|transport/i.test(message)) {
      err.transient = true;
    }
    throw err;
  }
  return body.payload || {};
}

async function loadSnapshot(force = false) {
  const now = Date.now();
  if (!force && snapshotCache.snapshot && now - snapshotCache.fetchedAtMs < FED_SYNC_CACHE_MS) {
    return snapshotCache.snapshot;
  }
  const payload = await gatewayPost("sync.full", {}, `sync-${randomUUID()}`, Math.max(4000, FED_DISPATCH_TIMEOUT_MS));
  const snapshot = payload?.snapshot;
  if (!snapshot || typeof snapshot !== "object") {
    throw new Error("gateway sync.full returned invalid snapshot");
  }
  snapshotCache.snapshot = snapshot;
  snapshotCache.fetchedAtMs = now;
  return snapshot;
}

function extractAgents(snapshot) {
  const agents = Array.isArray(snapshot?.agents) ? snapshot.agents : [];
  return agents
    .map((agent) => {
      const id = typeof agent?.id === "string" ? agent.id : null;
      if (!id) return null;
      const names = [agent?.name, agent?.displayName, agent?.title, agent?.label]
        .filter((value) => typeof value === "string" && value.trim().length > 0)
        .map((value) => value.trim());
      const tools = Array.isArray(agent?.tools) ? agent.tools : [];
      return { id, names, tools, raw: agent };
    })
    .filter(Boolean);
}

function compileTemplate(template, request) {
  const target = request.target == null ? "null" : String(request.target);
  const argsJSON = JSON.stringify(request.args || {});
  const replacements = {
    action: request.action,
    scope: request.scope,
    target,
    request_id: request.request_id,
    reason: request.reason,
    args_json: argsJSON,
    ts_ms: String(request.ts_ms),
  };
  return String(template || "")
    .replace(/\$\{([a-zA-Z0-9_]+)\}/g, (_full, key) => (key in replacements ? replacements[key] : ""))
    .trim();
}

function findToolId(agent, toolName) {
  const desired = String(toolName || "").trim().toLowerCase();
  if (!desired) return "";
  const normalizedTools = (agent?.tools || []).map((tool) => ({
    id: typeof tool?.id === "string" ? tool.id : "",
    names: [tool?.name, tool?.displayName, tool?.title, tool?.label]
      .filter((value) => typeof value === "string" && value.trim().length > 0)
      .map((value) => value.trim().toLowerCase()),
  }));
  const exact = normalizedTools.find((tool) => tool.id && tool.names.some((name) => name === desired));
  if (exact) return exact.id;
  const contains = normalizedTools.find((tool) => tool.id && tool.names.some((name) => name.includes(desired) || desired.includes(name)));
  return contains?.id || "";
}

async function resolveDispatchTarget(request, mapping) {
  const defaults = mapping.defaults || {};
  const actionMap = mapping.actions?.[request.action] || {};
  const dispatchOp = String(actionMap.dispatch_op || defaults.dispatch_op || "dispatch.intent").trim();
  if (dispatchOp !== "dispatch.intent" && dispatchOp !== "dispatch.tool") {
    throw new Error(`unsupported dispatch_op for action ${request.action}: ${dispatchOp}`);
  }

  const snapshot = await loadSnapshot(false);
  const agents = extractAgents(snapshot);
  if (agents.length === 0) {
    throw new Error("no agents available in gateway snapshot");
  }

  let selectedAgent = null;
  const explicitAgentID = String(actionMap.agent_id || "").trim();
  if (explicitAgentID) {
    selectedAgent = agents.find((agent) => agent.id === explicitAgentID) || null;
    if (!selectedAgent) {
      throw new Error(`mapped agent_id not present in snapshot for ${request.action}`);
    }
  } else {
    const selector = actionMap.agent_selector && typeof actionMap.agent_selector === "object"
      ? actionMap.agent_selector
      : defaults.agent_selector || {};
    const regexText = String(selector.name_regex || "").trim();
    if (regexText) {
      const matcher = new RegExp(regexText, "i");
      selectedAgent = agents.find((agent) => agent.names.some((name) => matcher.test(name)) || matcher.test(agent.id)) || null;
    }
    if (!selectedAgent && (actionMap.fallback_to_first_agent ?? defaults.fallback_to_first_agent ?? true)) {
      selectedAgent = agents[0];
    }
  }

  if (!selectedAgent) {
    throw new Error(`unable to resolve target agent for ${request.action}`);
  }

  if (dispatchOp === "dispatch.intent") {
    const template = actionMap.intent || defaults.intent_template
      || "sods.action ${action} scope=${scope} target=${target} request_id=${request_id} reason=${reason} args=${args_json}";
    const text = compileTemplate(template, request);
    if (!text) {
      throw new Error(`intent template resolved empty for ${request.action}`);
    }
    return {
      dispatchOp,
      agentID: selectedAgent.id,
      payload: {
        agentID: selectedAgent.id,
        text,
      },
      summary: {
        dispatch_op: dispatchOp,
        agent_id: selectedAgent.id,
        intent_preview: text.length > 200 ? `${text.slice(0, 200)}...` : text,
      },
    };
  }

  const explicitToolID = String(actionMap.tool_id || "").trim();
  let toolID = explicitToolID;
  if (!toolID) {
    toolID = findToolId(selectedAgent, actionMap.tool_name || defaults.tool_name || "");
  }
  if (!toolID) {
    throw new Error(`dispatch.tool requires tool_id or resolvable tool_name for ${request.action}`);
  }

  return {
    dispatchOp,
    agentID: selectedAgent.id,
    payload: {
      agentID: selectedAgent.id,
      toolID,
    },
    summary: {
      dispatch_op: dispatchOp,
      agent_id: selectedAgent.id,
      tool_id: toolID,
      tool_name: actionMap.tool_name || defaults.tool_name || "",
    },
  };
}

async function dispatchViaFederation(request) {
  const mapping = loadFederationTargets();
  const resolved = await resolveDispatchTarget(request, mapping);
  const op = resolved.dispatchOp;
  const gatewayOp = op === "dispatch.tool" ? "dispatch.tool" : "dispatch.intent";

  const payload = await retryTransient("federation dispatch", FED_DISPATCH_RETRIES, async () => {
    return gatewayPost(gatewayOp, resolved.payload, request.request_id, FED_DISPATCH_TIMEOUT_MS);
  });

  return {
    routed: resolved.summary,
    gateway_payload: payload,
  };
}

function currentFederationState() {
  let mapping = null;
  let error = "";
  try {
    mapping = loadFederationTargets();
  } catch (err) {
    error = String(err?.message || err);
    targetsCache.loadError = error;
  }
  return {
    mapping,
    mapping_error: error || targetsCache.loadError || "",
    target_file: resolvePath(FED_TARGETS_FILE),
  };
}

async function federationHealth() {
  const { mapping, mapping_error, target_file } = currentFederationState();

  try {
    const healthHeaders = { accept: "application/json" };
    if (FED_GATEWAY_BEARER) {
      healthHeaders.authorization = `Bearer ${FED_GATEWAY_BEARER}`;
    }
    const { response, text } = await fetchText(
      FED_GATEWAY_HEALTH_URL,
      { method: "GET", headers: healthHeaders },
      Math.max(2500, Math.min(FED_DISPATCH_TIMEOUT_MS, 7000)),
    );
    const body = parsedJSON(text);

    let upstreamOK = false;
    let upstreamDetail = text;
    if (response.ok && body && body.ok === true) {
      upstreamOK = true;
      upstreamDetail = "ok";
    } else if (response.ok && body && body.payload && body.ok === true) {
      upstreamOK = true;
      upstreamDetail = "ok";
    } else if (body?.error?.message) {
      upstreamDetail = body.error.message;
    } else if (!response.ok) {
      upstreamDetail = `HTTP ${response.status}`;
    }

    return {
      ok: upstreamOK && !mapping_error,
      codegatchi_gateway: {
        url: FED_GATEWAY_URL,
        health_url: FED_GATEWAY_HEALTH_URL,
        ok: upstreamOK,
        detail: upstreamDetail,
      },
      dispatch_mode: "federation-compat",
      tunnel: {
        host: FED_TUNNEL_HOST,
        remote_port: FED_TUNNEL_REMOTE_PORT,
      },
      target_file,
      mapping_schema: mapping?.schema_version || "unknown",
      mapping_error,
      auth_configured: FED_GATEWAY_BEARER.length > 0,
    };
  } catch (error) {
    return {
      ok: false,
      codegatchi_gateway: {
        url: FED_GATEWAY_URL,
        health_url: FED_GATEWAY_HEALTH_URL,
        ok: false,
        detail: String(error?.message || error),
      },
      dispatch_mode: "federation-compat",
      tunnel: {
        host: FED_TUNNEL_HOST,
        remote_port: FED_TUNNEL_REMOTE_PORT,
      },
      target_file,
      mapping_schema: mapping?.schema_version || "unknown",
      mapping_error,
      auth_configured: FED_GATEWAY_BEARER.length > 0,
    };
  }
}

async function dispatchGod(input) {
  const started = Date.now();
  const request = normalizeRequest(input);

  if (requestSeen.has(request.request_id)) {
    await vaultIngest(envelope("control.god_button.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: "duplicate request_id",
    }));
    throw new Error("duplicate request_id");
  }
  requestSeen.set(request.request_id, Date.now());

  if (!request.action || !ACTION_ALLOWLIST.has(request.action)) {
    await vaultIngest(envelope("control.god_button.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: "action missing or not allowlisted",
    }));
    throw new Error("action missing or not allowlisted");
  }

  const rl = enforceRateLimit(request.action);
  if (!rl.ok) {
    await vaultIngest(envelope("control.god_button.denied", {
      request_id: request.request_id,
      action: request.action,
      denied_reason: rl.reason,
    }));
    throw new Error(rl.reason);
  }

  await vaultIngest(envelope("control.god_button.intent", { request }));

  const dryRun = isDryRun(request);
  let dispatchResult = null;
  if (!dryRun) {
    dispatchResult = await dispatchViaFederation(request);
  }

  const result = {
    ok: true,
    handled_by: IDENTITY,
    duration_ms: Date.now() - started,
    result_summary: dryRun
      ? "dry-run accepted (no federation dispatch)"
      : `dispatched via federation (${dispatchResult?.routed?.dispatch_op || "dispatch.intent"})`,
    dispatch_mode: "federation-compat",
    routed: dispatchResult?.routed || null,
    gateway: dryRun ? null : dispatchResult?.gateway_payload || null,
    dry_run: dryRun,
  };

  void vaultIngest(envelope("control.god_button.result", {
    request_id: request.request_id,
    action: request.action,
    result,
  })).catch((error) => {
    console.error(`vault result ingest failed: ${String(error?.message || error)}`);
  });

  return { request, result };
}

const app = express();
app.use(express.json());

app.get("/health", async (_req, res) => {
  const health = await federationHealth();
  if (health.ok) {
    res.json({ ok: true, identity: IDENTITY, ...health });
    return;
  }
  res.status(503).json({ ok: false, identity: IDENTITY, ...health });
});

app.post("/god", async (req, res) => {
  try {
    const output = await dispatchGod(req.body ?? {});
    res.json({ ok: true, ...output });
  } catch (error) {
    console.error(`god dispatch failed: ${String(error?.message || error)}`);
    res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.listen(PORT, HOST, async () => {
  console.log(`god gateway on http://${HOST}:${PORT}/god (federation mode)`);
  const health = await federationHealth();
  if (health.ok) {
    console.log(`federation gateway ready via ${FED_GATEWAY_HEALTH_URL}`);
  } else {
    console.error(`initial federation health check failed: ${health.codegatchi_gateway?.detail || "unknown"}`);
  }
});
