import { Room } from "@livekit/rtc-node";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { resolve, isAbsolute } from "node:path";
import { readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";

const AUX_HOST = process.env.AUX_HOST || "192.168.8.114";
const LOGGER_HOST = process.env.LOGGER_HOST || "192.168.8.160";
const LIVEKIT_URL = process.env.LIVEKIT_URL || `ws://${AUX_HOST}:7880`;
const TOKEN_ENDPOINT = process.env.TOKEN_ENDPOINT || `http://${AUX_HOST}:9123/token`;
const ROOM_NAME = process.env.ROOM_NAME || "strangelab";
const IDENTITY = process.env.IDENTITY || "exec-agent";

const VAULT_INGEST_URL = process.env.VAULT_INGEST_URL || `http://${LOGGER_HOST}:8088/v1/ingest`;
const NODE_ID = process.env.NODE_ID || IDENTITY;
const DEVICE_ID = process.env.DEVICE_ID || inferDeviceId();
const ROLE = process.env.NODE_ROLE || "edge";
const AGENT_VERSION = "strangelab-exec-agent-v2";
const AUX_CIDR = process.env.AUX_CIDR || "192.168.8.0/24";
const AUX_GATEWAY = process.env.AUX_GATEWAY || "192.168.8.1";

const DEFAULT_TIMEOUT_MS = Number(process.env.DEFAULT_TIMEOUT_MS || 30_000);
const HEALTH_INTERVAL_MS = Number(process.env.HEALTH_INTERVAL_MS || 60_000);
const MAX_OUTPUT_BYTES = 256 * 1024;
const CLAIM_DB_PATH = process.env.CLAIM_DB_PATH || "/opt/strangelab/claims/claimed-nodes.json";
const CAPABILITIES_PATH = process.env.CAPABILITIES_PATH || "/opt/strangelab/capabilities.json";

const RATE_LIMITS_PER_MIN = {
  panic: 5,
  snapshot: 30,
  maint: 20,
  scan: 6,
  build: 3,
  ritual: 10,
  ops: 20,
};

const DEDUPE_WINDOW_MS = 10 * 60_000;
const BASE_CWD_ALLOW = ["/opt/strangelab", process.cwd()];
const ROOT_CWD_ALLOW = ["/"];
const requestSeen = new Map();
const rateBuckets = new Map();

const ALLOW = {
  "/usr/bin/uptime": { maxArgs: 0, cwdAllow: BASE_CWD_ALLOW },
  "/usr/bin/whoami": { maxArgs: 0, cwdAllow: BASE_CWD_ALLOW },
  "/usr/bin/uname": { maxArgs: 4, cwdAllow: BASE_CWD_ALLOW },
  "/bin/ls": { maxArgs: 16, cwdAllow: ["/opt/strangelab", "/tmp", process.cwd()] },
  "/usr/bin/git": { maxArgs: 20, cwdAllow: BASE_CWD_ALLOW },
  "/bin/ps": { maxArgs: 8, cwdAllow: ROOT_CWD_ALLOW },
  "/usr/bin/top": { maxArgs: 8, cwdAllow: ROOT_CWD_ALLOW },

  "/bin/systemctl": { maxArgs: 8, cwdAllow: ROOT_CWD_ALLOW },
  "/usr/bin/journalctl": { maxArgs: 16, cwdAllow: ROOT_CWD_ALLOW },

  "/bin/df": { maxArgs: 4, cwdAllow: ROOT_CWD_ALLOW },
  "/bin/ping": { maxArgs: 8, cwdAllow: ROOT_CWD_ALLOW },
  "/usr/sbin/arp": { maxArgs: 8, cwdAllow: ROOT_CWD_ALLOW },
  "/sbin/ip": { maxArgs: 12, cwdAllow: ROOT_CWD_ALLOW },
  "/sbin/ifconfig": { maxArgs: 12, cwdAllow: ROOT_CWD_ALLOW },
  "/sbin/route": { maxArgs: 12, cwdAllow: ROOT_CWD_ALLOW },

  "/usr/bin/nmap": { maxArgs: 16, cwdAllow: ROOT_CWD_ALLOW },
  "/opt/homebrew/bin/nmap": { maxArgs: 16, cwdAllow: ROOT_CWD_ALLOW },

  "/usr/bin/python3": { maxArgs: 64, cwdAllow: BASE_CWD_ALLOW },
  "/usr/local/bin/esptool.py": { maxArgs: 128, cwdAllow: BASE_CWD_ALLOW },
  "/usr/bin/esptool.py": { maxArgs: 128, cwdAllow: BASE_CWD_ALLOW },
  "/opt/homebrew/bin/esptool.py": { maxArgs: 128, cwdAllow: BASE_CWD_ALLOW },
  "/usr/bin/idf.py": { maxArgs: 128, cwdAllow: BASE_CWD_ALLOW },
  "/opt/homebrew/bin/idf.py": { maxArgs: 128, cwdAllow: BASE_CWD_ALLOW },
};

const LEGACY_GOD_OP_MAP = {
  panic: "panic.freeze.agents",
  whoami: "ritual.rollcall",
};

const ACTION_ALLOWLIST = new Set([
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

let agentFrozen = false;
let quietMode = false;

function sha256(s) {
  return createHash("sha256").update(s).digest("hex");
}

function inferDeviceId() {
  const host = os.hostname();
  const mid = ["/etc/machine-id", "/var/lib/dbus/machine-id"].find((p) => existsSync(p));
  let stable = host;
  if (mid) stable = `${host}:${readFileSync(mid, "utf8").trim()}`;
  return `host:${sha256(stable).slice(0, 16)}`;
}

function detectPlatformClass() {
  return process.platform === "darwin" ? "mac" : "pi";
}

function capabilityClass(action) {
  const prefix = String(action || "").split(".")[0];
  if (["panic", "snapshot", "maint", "scan", "build", "ritual"].includes(prefix)) return prefix;
  return "";
}

function denyAllNonSnapshotCaps() {
  return {
    node_id: NODE_ID,
    roles: [ROLE],
    capabilities: {
      panic: { enabled: false, scopes: [], tools: [] },
      snapshot: { enabled: true, scopes: ["all", "node", "tier1", "mac", "pi"], tools: [] },
      maint: { enabled: false, scopes: [], tools: [] },
      scan: { enabled: false, scopes: [], tools: [] },
      build: { enabled: false, scopes: [], tools: [] },
      ritual: { enabled: false, scopes: [], tools: [] },
    },
  };
}

function normalizeCapClass(v) {
  if (!v || typeof v !== "object") return { enabled: false, scopes: [], tools: [] };
  const scopes = Array.isArray(v.scopes) ? v.scopes.map((s) => String(s)) : [];
  const tools = Array.isArray(v.tools) ? v.tools.map((s) => String(s)) : [];
  return { enabled: v.enabled === true, scopes, tools };
}

function loadCapabilitiesState() {
  if (!existsSync(CAPABILITIES_PATH)) {
    return { valid: false, reason: "capability file missing", data: denyAllNonSnapshotCaps() };
  }
  try {
    const parsed = JSON.parse(readFileSync(CAPABILITIES_PATH, "utf8"));
    if (!parsed || typeof parsed !== "object" || !parsed.capabilities || typeof parsed.capabilities !== "object") {
      return { valid: false, reason: "invalid capability schema", data: denyAllNonSnapshotCaps() };
    }
    const data = {
      node_id: String(parsed.node_id || NODE_ID),
      roles: Array.isArray(parsed.roles) ? parsed.roles.map((r) => String(r)) : [ROLE],
      capabilities: {
        panic: normalizeCapClass(parsed.capabilities.panic),
        snapshot: normalizeCapClass(parsed.capabilities.snapshot),
        maint: normalizeCapClass(parsed.capabilities.maint),
        scan: normalizeCapClass(parsed.capabilities.scan),
        build: normalizeCapClass(parsed.capabilities.build),
        ritual: normalizeCapClass(parsed.capabilities.ritual),
      },
    };
    return { valid: true, reason: "", data };
  } catch (error) {
    return { valid: false, reason: `capability parse failed: ${String(error?.message || error)}`, data: denyAllNonSnapshotCaps() };
  }
}

let CAPS_STATE = loadCapabilitiesState();

function toolAliasFromCommand(cmd) {
  const map = {
    "/bin/systemctl": "systemctl",
    "/usr/bin/journalctl": "journalctl",
    "/bin/df": "df",
    "/bin/ping": "ping",
    "/sbin/ip": "ip",
    "/sbin/ifconfig": "ifconfig",
    "/sbin/route": "route",
    "/usr/bin/nmap": "nmap",
    "/opt/homebrew/bin/nmap": "nmap",
    "/usr/bin/python3": "python3",
    "/usr/bin/esptool.py": "esptool",
    "/usr/local/bin/esptool.py": "esptool",
    "/opt/homebrew/bin/esptool.py": "esptool",
    "/usr/bin/idf.py": "idf.py",
    "/opt/homebrew/bin/idf.py": "idf.py",
    "/bin/ps": "ps",
    "/usr/bin/top": "top",
  };
  return map[cmd] || "";
}

function capabilityDecision(action, scope, toolAlias = "") {
  const cls = capabilityClass(action);
  if (!cls) return { ok: false, reason: "unknown capability class" };
  const spec = CAPS_STATE.data.capabilities[cls];
  if (!spec || spec.enabled !== true) return { ok: false, reason: `capability disabled: ${cls}` };
  if (scope && Array.isArray(spec.scopes) && spec.scopes.length > 0 && !spec.scopes.includes(scope)) {
    return { ok: false, reason: `scope denied for ${cls}: ${scope}` };
  }
  if (toolAlias && Array.isArray(spec.tools) && spec.tools.length > 0 && !spec.tools.includes(toolAlias)) {
    return { ok: false, reason: `tool denied for ${cls}: ${toolAlias}` };
  }
  return { ok: true, reason: "" };
}

function checkActionAllowed(action) {
  return ACTION_ALLOWLIST.has(action);
}

function safeResolveCwd(cwd) {
  if (!cwd) return process.cwd();
  return resolve(cwd);
}

function isCwdAllowed(cmd, cwdResolved) {
  const rule = ALLOW[cmd];
  if (!rule) return false;
  for (const base of rule.cwdAllow) {
    const baseR = resolve(base);
    if (cwdResolved === baseR) return true;
    if (cwdResolved.startsWith(baseR + "/")) return true;
  }
  return false;
}

function validateArgs(cmd, args) {
  if (cmd.endsWith("nmap")) {
    const allowed = new Set(["-sn", "-T4", "--top-ports", "100", "50", "10", "-Pn"]);
    for (const arg of args) {
      if (arg.startsWith("-") && !allowed.has(arg)) return false;
    }
  }
  if (cmd === "/bin/systemctl") {
    const allowedSub = new Set(["status", "restart", "is-active"]);
    if (!allowedSub.has(args[0] || "")) return false;
  }
  if (cmd === "/usr/bin/top") {
    const allowedTop = new Set(["-l", "1", "-n", "1", "-b", "-bn1"]);
    for (const arg of args) {
      if (arg.startsWith("-") && !allowedTop.has(arg)) return false;
    }
  }
  return true;
}

function gcMaps() {
  const now = Date.now();
  for (const [rid, ts] of requestSeen) {
    if (now - ts > DEDUPE_WINDOW_MS) requestSeen.delete(rid);
  }
  for (const [cat, entries] of rateBuckets) {
    const kept = entries.filter((ts) => now - ts < 60_000);
    rateBuckets.set(cat, kept);
  }
}

function categoryForAction(action) {
  if (!action) return "ops";
  const prefix = action.split(".")[0];
  if (RATE_LIMITS_PER_MIN[prefix]) return prefix;
  return "ops";
}

function enforceRateLimit(action) {
  gcMaps();
  const cat = categoryForAction(action);
  const limit = RATE_LIMITS_PER_MIN[cat] || 20;
  const now = Date.now();
  const list = rateBuckets.get(cat) || [];
  if (list.length >= limit) {
    return { ok: false, reason: `rate limit exceeded for ${cat}` };
  }
  list.push(now);
  rateBuckets.set(cat, list);
  return { ok: true };
}

function shouldHandleForScope(message) {
  const scope = String(message.scope || "all");
  const target = String(message.target || message.node_id || "");
  const cls = detectPlatformClass();

  if (scope === "all") return true;
  if (scope === "node") return target === NODE_ID;
  if (scope === "tier1") return ROLE === "tier1";
  if (scope === "mac") return cls === "mac";
  if (scope === "pi") return cls === "pi";
  return !target || target === NODE_ID;
}

function normalizedActionMessage(topic, msg) {
  const requestId = String(msg.request_id || randomUUID());
  const legacyOp = String(msg.op || "");
  const action = String(msg.action || LEGACY_GOD_OP_MAP[legacyOp] || "");
  return {
    topic,
    request_id: requestId,
    action,
    scope: String(msg.scope || "all"),
    target: msg.target ?? msg.node_id ?? null,
    reason: String(msg.reason || ""),
    args: typeof msg.args === "object" && msg.args ? msg.args : {},
    op: legacyOp,
    raw: msg,
  };
}

async function vaultIngest(event) {
  const r = await fetch(VAULT_INGEST_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(event),
  });
  if (!r.ok) {
    const t = await r.text().catch(() => "");
    throw new Error(`vault ingest failed: ${r.status} ${t}`);
  }
}

function envelope(type, data) {
  return {
    type,
    src: NODE_ID,
    ts_ms: Date.now(),
    data: {
      node_id: NODE_ID,
      device_id: DEVICE_ID,
      role: ROLE,
      ...data,
    },
  };
}

async function getToken() {
  const r = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identity: IDENTITY, room: ROOM_NAME }),
  });
  const j = await r.json();
  if (!j.ok) throw new Error(j.error || "token endpoint failed");
  return j.token;
}

function clampBytes(buf, max) {
  if (buf.length <= max) return buf;
  return buf.subarray(0, max);
}

async function runCommand(cmd, args, cwd, timeoutMs) {
  if (!isAbsolute(cmd)) return { ok: false, error: "cmd must be absolute", code: "BAD_CMD" };

  const rule = ALLOW[cmd];
  if (!rule) return { ok: false, error: "command not allowed", code: "NOT_ALLOWED" };
  if (args.length > rule.maxArgs) return { ok: false, error: "too many args", code: "ARGS_LIMIT" };
  if (!validateArgs(cmd, args)) return { ok: false, error: "disallowed argument", code: "BAD_ARGS" };

  const cwdResolved = safeResolveCwd(cwd);
  if (!isCwdAllowed(cmd, cwdResolved)) {
    return { ok: false, error: "cwd not allowed", code: "CWD_NOT_ALLOWED", cwd: cwdResolved };
  }

  const start = Date.now();
  const child = spawn(cmd, args, { cwd: cwdResolved, stdio: ["ignore", "pipe", "pipe"], shell: false });

  let stdout = Buffer.alloc(0);
  let stderr = Buffer.alloc(0);
  let killed = false;

  const killTimer = setTimeout(() => {
    killed = true;
    child.kill("SIGKILL");
  }, timeoutMs);

  child.stdout.on("data", (d) => {
    if (stdout.length < MAX_OUTPUT_BYTES) stdout = Buffer.concat([stdout, d]);
  });
  child.stderr.on("data", (d) => {
    if (stderr.length < MAX_OUTPUT_BYTES) stderr = Buffer.concat([stderr, d]);
  });

  const exit = await new Promise((resolvePromise) => {
    child.on("error", (err) => resolvePromise({ code: -1, signal: null, error: String(err?.message || err) }));
    child.on("close", (code, signal) => resolvePromise({ code: code ?? -1, signal: signal ?? null, error: null }));
  });

  clearTimeout(killTimer);
  stdout = clampBytes(stdout, MAX_OUTPUT_BYTES);
  stderr = clampBytes(stderr, MAX_OUTPUT_BYTES);

  return {
    ok: exit.error ? false : true,
    exit_code: exit.code,
    signal: exit.signal,
    timed_out: killed,
    duration_ms: Date.now() - start,
    stdout: stdout.toString("utf8"),
    stderr: stderr.toString("utf8"),
    spawn_error: exit.error,
    cmd,
    args,
    cwd: cwdResolved,
  };
}

function readClaims() {
  if (!existsSync(CLAIM_DB_PATH)) return [];
  try {
    const text = readFileSync(CLAIM_DB_PATH, "utf8");
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeClaims(items) {
  mkdirSync(resolve(CLAIM_DB_PATH, ".."), { recursive: true });
  writeFileSync(CLAIM_DB_PATH, JSON.stringify(items, null, 2));
}

async function healthSnapshot(trigger, extra = {}) {
  const host = os.hostname();
  const load = os.loadavg();
  const memFree = os.freemem();
  const memTotal = os.totalmem();

  const uptime = await runCommand("/usr/bin/uptime", [], process.cwd(), 10_000);
  const disk = await runCommand("/bin/df", ["-h"], "/", 10_000);

  const netCmd = process.platform === "darwin"
    ? { cmd: "/sbin/ifconfig", args: ["-a"], cwd: "/" }
    : { cmd: "/sbin/ip", args: ["addr", "show"], cwd: "/" };
  const net = await runCommand(netCmd.cmd, netCmd.args, netCmd.cwd, 10_000);

  await vaultIngest(envelope("node.health.snapshot", {
    trigger,
    host,
    uptime_s: os.uptime(),
    cpu_load: { l1: load[0], l5: load[1], l15: load[2] },
    mem_free: memFree,
    mem_total: memTotal,
    service_status: {
      exec_agent: "running",
    },
    versions: {
      node: process.version,
      agent: AGENT_VERSION,
    },
    net: {
      ok: net.ok,
      details: net.stdout,
    },
    probes: {
      uptime: { ok: uptime.ok, stdout: uptime.stdout },
      disk: { ok: disk.ok, stdout: disk.stdout },
    },
    ...extra,
  }));
}

async function executeWithAudit({ typeIntent, typeResult, requestId, from, action, command, topic }) {
  const started = Date.now();
  const commandSummary = {
    cmd: command.cmd,
    args: Array.isArray(command.args) ? command.args : [],
    cwd: command.cwd,
  };

  await vaultIngest(envelope(typeIntent, {
    request_id: requestId,
    from,
    action,
    command: commandSummary,
    topic,
  }));

  // Keep a unified execution stream for feed/trace consumers.
  await vaultIngest(envelope("agent.exec.intent", {
    request_id: requestId,
    from,
    action,
    command: commandSummary,
    topic,
  }));

  const reqHash = sha256(JSON.stringify({ requestId, action, command }));
  const result = await runCommand(command.cmd, command.args, command.cwd, DEFAULT_TIMEOUT_MS);
  const auditedResult = {
    request_id: requestId,
    from,
    action,
    command: commandSummary,
    ok: result.ok,
    exit_code: result.exit_code,
    signal: result.signal,
    timed_out: result.timed_out,
    duration_ms: result.duration_ms,
    stdout_sha256: sha256(result.stdout || ""),
    stderr_sha256: sha256(result.stderr || ""),
    stdout: result.stdout,
    stderr: result.stderr,
    spawn_error: result.spawn_error,
    req_hash: reqHash,
    handled_by: NODE_ID,
    total_duration_ms: Date.now() - started,
  };

  await vaultIngest(envelope(typeResult, auditedResult));
  await vaultIngest(envelope("agent.exec.result", auditedResult));
}

async function emitDryRunResult({ requestId, action, from, ok, deniedReason }) {
  await vaultIngest(envelope("control.god_button.result", {
    request_id: requestId,
    action,
    from,
    dry_run: true,
    ok,
    denied_reason: deniedReason || "",
    handled_by: NODE_ID,
    result_summary: ok ? "dry-run validation passed" : `dry-run denied: ${deniedReason}`,
  }));
}

function commandForMaintenance(action, args = {}) {
  if (action === "maint.status.service") {
    const service = String(args.service || "strangelab-exec-agent");
    return { cmd: "/bin/systemctl", args: ["status", service, "--no-pager"], cwd: "/" };
  }
  if (action === "maint.restart.service") {
    const service = String(args.service || "strangelab-exec-agent");
    return { cmd: "/bin/systemctl", args: ["restart", service], cwd: "/" };
  }
  if (action === "maint.logs.tail") {
    const service = String(args.service || "strangelab-exec-agent");
    const lines = Math.max(10, Math.min(400, Number(args.lines || 120)));
    return { cmd: "/usr/bin/journalctl", args: ["-u", service, "-n", String(lines), "--no-pager"], cwd: "/" };
  }
  if (action === "maint.disk.df") {
    return { cmd: "/bin/df", args: ["-h"], cwd: "/" };
  }
  if (action === "maint.net.ping") {
    const target = String(args.target || AUX_HOST);
    return { cmd: "/bin/ping", args: ["-c", "3", target], cwd: "/" };
  }
  return null;
}

function commandForScan(action, args = {}) {
  if (action === "scan.lan.fast") {
    const target = String(args.target || AUX_CIDR);
    const cmd = existsSync("/usr/bin/nmap") ? "/usr/bin/nmap" : "/opt/homebrew/bin/nmap";
    return { cmd, args: ["-sn", "-T4", target], cwd: "/" };
  }
  if (action === "scan.lan.ports.top") {
    const target = String(args.target || AUX_GATEWAY);
    const topPorts = String(args.top_ports || "100");
    const cmd = existsSync("/usr/bin/nmap") ? "/usr/bin/nmap" : "/opt/homebrew/bin/nmap";
    return { cmd, args: ["--top-ports", topPorts, "-T4", target], cwd: "/" };
  }
  if (action === "scan.wifi.snapshot") {
    if (process.platform === "darwin") return { cmd: "/sbin/ifconfig", args: ["-a"], cwd: "/" };
    return { cmd: "/sbin/ip", args: ["addr", "show"], cwd: "/" };
  }
  if (action === "scan.ble.sweep") {
    // Keep BLE sweep bounded and portable; use local interface snapshot as safe probe.
    if (process.platform === "darwin") return { cmd: "/sbin/ifconfig", args: ["-a"], cwd: "/" };
    return { cmd: "/sbin/ip", args: ["addr", "show"], cwd: "/" };
  }
  return null;
}

async function handleClaimAction(message, from) {
  const claimCode = String(message.args.claim_code || "").trim();
  const boardId = String(message.args.board_id || "").trim();
  const fwVersion = String(message.args.fw_version || "").trim();
  const claim = {
    request_id: message.request_id,
    from,
    node_id: String(message.args.node_id || NODE_ID),
    device_id: String(message.args.device_id || claimCode || DEVICE_ID),
    role: String(message.args.role || ROLE),
    hw: String(message.args.hw || os.platform()),
    fw: String(message.args.fw || fwVersion || AGENT_VERSION),
    transport: String(message.args.transport || "local"),
    ip: String(message.args.ip || ""),
    mac: String(message.args.mac || ""),
    board_id: boardId,
    claim_code: claimCode,
    serial_port: String(message.args.serial_port || ""),
    notes: String(message.args.notes || ""),
    first_seen_ts_ms: Date.now(),
  };

  await vaultIngest(envelope("node.claim.intent", { request_id: message.request_id, from, claim }));
  const claims = readClaims().filter((item) => item.device_id !== claim.device_id);
  claims.push(claim);
  writeClaims(claims);
  await vaultIngest(envelope("node.claim.result", { request_id: message.request_id, from, ok: true, claim }));
}

async function handleFlashAction(message, from) {
  const flash = message.args.flash || message.args || {};
  const intent = {
    request_id: message.request_id,
    from,
    node_id: String(flash.node_id || NODE_ID),
    device_id: String(flash.device_id || ""),
    serial_port: String(flash.serial_port || ""),
    baud: Number(flash.baud || 115200),
    firmware_name: String(flash.firmware_name || ""),
    firmware_version: String(flash.firmware_version || ""),
    artifact_paths: Array.isArray(flash.artifact_paths) ? flash.artifact_paths : [],
    steps: Array.isArray(flash.steps) ? flash.steps : [],
  };

  await vaultIngest(envelope("node.flash.intent", intent));

  for (const artifact of intent.artifact_paths) {
    if (!existsSync(String(artifact))) {
      await vaultIngest(envelope("node.flash.result", {
        request_id: message.request_id,
        from,
        ok: false,
        error: `missing artifact: ${artifact}`,
      }));
      return;
    }
  }

  if (intent.device_id && String(message.args.probe_device_id || "") && intent.device_id !== String(message.args.probe_device_id)) {
    await vaultIngest(envelope("node.flash.result", {
      request_id: message.request_id,
      from,
      ok: false,
      error: "device_id mismatch",
      expected_device_id: intent.device_id,
      probed_device_id: String(message.args.probe_device_id),
    }));
    return;
  }

  const results = [];
  for (const step of intent.steps) {
    const cmd = String(step.cmd || "");
    const args = Array.isArray(step.args) ? step.args.map((a) => String(a)) : [];
    const cwd = String(step.cwd || process.cwd());
    const run = await runCommand(cmd, args, cwd, DEFAULT_TIMEOUT_MS);
    results.push(run);
    if (!run.ok || run.exit_code !== 0) {
      await vaultIngest(envelope("node.flash.result", {
        request_id: message.request_id,
        from,
        ok: false,
        step: { cmd, args, cwd },
        result: run,
        stdout_sha256: sha256(run.stdout || ""),
        stderr_sha256: sha256(run.stderr || ""),
      }));
      return;
    }
  }

  await vaultIngest(envelope("node.flash.result", {
    request_id: message.request_id,
    from,
    ok: true,
    steps_run: results.length,
    results,
    post_flash_probe: {
      device_id: intent.device_id || null,
    },
  }));
}

async function handleSnapshotAction(message, from) {
  const action = message.action;
  if (action === "snapshot.now") {
    await healthSnapshot("snapshot.now", { request_id: message.request_id, from });
    return;
  }
  if (action === "snapshot.services") {
    const cmd = process.platform === "darwin"
      ? { cmd: "/bin/ps", args: ["aux"], cwd: "/" }
      : { cmd: "/bin/systemctl", args: ["status", "strangelab-exec-agent", "--no-pager"], cwd: "/" };
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action,
      command: cmd,
      topic: message.topic,
    });
    return;
  }
  if (action === "snapshot.net.routes") {
    const cmd = process.platform === "darwin"
      ? { cmd: "/sbin/route", args: ["-n", "get", "default"], cwd: "/" }
      : { cmd: "/sbin/ip", args: ["route", "show"], cwd: "/" };
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action,
      command: cmd,
      topic: message.topic,
    });
    return;
  }
  if (action === "snapshot.vault.verify") {
    await vaultIngest(envelope("node.maintenance.intent", {
      request_id: message.request_id,
      from,
      action,
      check: "vault.verify",
    }));
    const probe = {
      type: "vault.verify.probe",
      src: NODE_ID,
      ts_ms: Date.now(),
      data: {
        node_id: NODE_ID,
        device_id: DEVICE_ID,
        role: ROLE,
        request_id: message.request_id,
      },
    };
    await vaultIngest(probe);
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action,
      ok: true,
      result_summary: "vault ingest probe written",
    }));
  }
}

async function handlePanicAction(message, from) {
  const action = message.action;
  await vaultIngest(envelope("node.maintenance.intent", {
    request_id: message.request_id,
    from,
    action,
  }));

  if (action === "panic.freeze.agents") {
    agentFrozen = true;
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action,
      ok: true,
      result_summary: "agents frozen",
    }));
    return;
  }

  if (action === "panic.lockdown.egress") {
    const command = process.platform === "darwin"
      ? { cmd: "/sbin/route", args: ["-n", "get", "default"], cwd: "/" }
      : { cmd: "/sbin/ip", args: ["route", "show"], cwd: "/" };
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action,
      command,
      topic: message.topic,
    });
    return;
  }

  if (action === "panic.isolate.node") {
    const target = String(message.args.target || AUX_GATEWAY);
    const command = { cmd: "/bin/ping", args: ["-c", "1", target], cwd: "/" };
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action,
      command,
      topic: message.topic,
    });
    return;
  }

  if (action === "panic.kill.switch") {
    const service = String(message.args.service || "strangelab-exec-agent");
    const command = { cmd: "/bin/systemctl", args: ["status", service, "--no-pager"], cwd: "/" };
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action,
      command,
      topic: message.topic,
    });
    return;
  }

  await vaultIngest(envelope("node.maintenance.result", {
    request_id: message.request_id,
    from,
    action,
    ok: false,
    result_summary: "panic action not implemented on this host",
  }));
}

async function handleRitualAction(message, from) {
  const action = message.action;
  if (action === "ritual.wake.mode") {
    agentFrozen = false;
    quietMode = false;
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action,
      ok: true,
      result_summary: "wake mode enabled",
    }));
    return;
  }

  if (action === "ritual.quiet.mode") {
    quietMode = true;
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action,
      ok: true,
      result_summary: "quiet mode enabled",
    }));
    return;
  }

  if (action === "ritual.rollcall") {
    await vaultIngest(envelope("node.claim.result", {
      request_id: message.request_id,
      from,
      ok: true,
      claim: {
        node_id: NODE_ID,
        device_id: DEVICE_ID,
        role: ROLE,
        hw: os.platform(),
        fw: AGENT_VERSION,
        transport: detectPlatformClass(),
        notes: "rollcall",
      },
    }));
    return;
  }

  if (action === "ritual.heartbeat.burst") {
    for (let i = 0; i < 10; i += 1) {
      await healthSnapshot("ritual.heartbeat.burst", { request_id: message.request_id, burst_index: i + 1 });
    }
    return;
  }
}

async function handleBuildAction(message, from) {
  const action = message.action;
  if (action === "build.version.report") {
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action,
      ok: true,
      result_summary: "version report",
      versions: {
        node: process.version,
        agent: AGENT_VERSION,
        os: `${process.platform}-${process.arch}`,
      },
    }));
    return;
  }

  if (action === "build.flash.target") {
    await handleFlashAction(message, from);
    return;
  }

  if (action === "build.rollback.target") {
    await handleFlashAction({
      ...message,
      action,
      args: {
        ...message.args,
        flash: message.args.flash || message.args,
      },
    }, from);
    return;
  }

  if (action === "build.deploy.config") {
    const config = message.args.config || message.args || {};
    const steps = Array.isArray(config.steps) ? config.steps : [];
    await vaultIngest(envelope("node.maintenance.intent", {
      request_id: message.request_id,
      from,
      action,
      steps_count: steps.length,
    }));
    if (steps.length === 0) {
      await vaultIngest(envelope("node.maintenance.result", {
        request_id: message.request_id,
        from,
        action,
        ok: false,
        result_summary: "deploy config missing steps",
      }));
      return;
    }
    for (const step of steps) {
      const cmd = String(step.cmd || "");
      const args = Array.isArray(step.args) ? step.args.map((a) => String(a)) : [];
      const cwd = String(step.cwd || process.cwd());
      const run = await runCommand(cmd, args, cwd, DEFAULT_TIMEOUT_MS);
      if (!run.ok || run.exit_code !== 0) {
        await vaultIngest(envelope("node.maintenance.result", {
          request_id: message.request_id,
          from,
          action,
          ok: false,
          result_summary: "deploy config step failed",
          step: { cmd, args, cwd },
          stdout_sha256: sha256(run.stdout || ""),
          stderr_sha256: sha256(run.stderr || ""),
          result: run,
        }));
        return;
      }
    }
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action,
      ok: true,
      result_summary: "deploy config complete",
      steps_run: steps.length,
    }));
    return;
  }

  await vaultIngest(envelope("node.maintenance.result", {
    request_id: message.request_id,
    from,
    action,
    ok: false,
    result_summary: "build action not mapped",
  }));
}

async function handleActionMessage(message, from) {
  const dryRun = message.raw?.dry_run === true || message.args?.dry_run === true;

  if (!message.action) {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: "",
        from,
        ok: false,
        deniedReason: "missing action",
      });
    }
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action: "",
      ok: false,
      result_summary: "missing action",
    }));
    return;
  }

  if (requestSeen.has(message.request_id)) {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: message.action,
        from,
        ok: false,
        deniedReason: "duplicate request_id",
      });
    }
    return;
  }
  requestSeen.set(message.request_id, Date.now());

  if (!shouldHandleForScope(message)) return;

  if (!checkActionAllowed(message.action)) {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: message.action,
        from,
        ok: false,
        deniedReason: "action not allowlisted",
      });
    }
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action: message.action,
      ok: false,
      result_summary: "action not allowlisted",
    }));
    return;
  }

  const rate = enforceRateLimit(message.action);
  if (!rate.ok) {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: message.action,
        from,
        ok: false,
        deniedReason: rate.reason,
      });
    }
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action: message.action,
      ok: false,
      result_summary: rate.reason,
    }));
    return;
  }

  const preDecision = capabilityDecision(message.action, message.scope || "all", "");
  if (!preDecision.ok) {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: message.action,
        from,
        ok: false,
        deniedReason: preDecision.reason,
      });
    }
    await vaultIngest(envelope("agent.capability.denied", {
      request_id: message.request_id,
      from,
      action: message.action,
      denied_reason: preDecision.reason,
    }));
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action: message.action,
      ok: false,
      result_summary: preDecision.reason,
    }));
    return;
  }

  if (agentFrozen && !message.action.startsWith("panic.") && message.action !== "ritual.wake.mode") {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: message.action,
        from,
        ok: false,
        deniedReason: "agent frozen",
      });
    }
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action: message.action,
      ok: false,
      result_summary: "agent frozen",
    }));
    return;
  }

  if (quietMode && message.action.startsWith("scan.")) {
    if (dryRun) {
      await emitDryRunResult({
        requestId: message.request_id,
        action: message.action,
        from,
        ok: false,
        deniedReason: "quiet mode blocks scans",
      });
    }
    await vaultIngest(envelope("node.maintenance.result", {
      request_id: message.request_id,
      from,
      action: message.action,
      ok: false,
      result_summary: "quiet mode blocks scans",
    }));
    return;
  }

  if (dryRun) {
    await emitDryRunResult({
      requestId: message.request_id,
      action: message.action,
      from,
      ok: true,
      deniedReason: "",
    });
    return;
  }

  if (message.action.startsWith("snapshot.")) {
    await handleSnapshotAction(message, from);
    return;
  }
  if (message.action.startsWith("maint.")) {
    const command = commandForMaintenance(message.action, message.args);
    if (!command) {
      await vaultIngest(envelope("node.maintenance.result", {
        request_id: message.request_id,
        from,
        action: message.action,
        ok: false,
        result_summary: "maintenance action not mapped",
      }));
      return;
    }
    const dec = capabilityDecision(message.action, message.scope || "all", toolAliasFromCommand(command.cmd));
    if (!dec.ok) {
      await vaultIngest(envelope("agent.capability.denied", {
        request_id: message.request_id,
        from,
        action: message.action,
        denied_reason: dec.reason,
      }));
      await vaultIngest(envelope("node.maintenance.result", {
        request_id: message.request_id,
        from,
        action: message.action,
        ok: false,
        result_summary: dec.reason,
      }));
      return;
    }
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action: message.action,
      command,
      topic: message.topic,
    });
    return;
  }
  if (message.action.startsWith("scan.")) {
    const command = commandForScan(message.action, message.args);
    if (!command) {
      await vaultIngest(envelope("node.maintenance.result", {
        request_id: message.request_id,
        from,
        action: message.action,
        ok: false,
        result_summary: "scan action not mapped",
      }));
      return;
    }
    const dec = capabilityDecision(message.action, message.scope || "all", toolAliasFromCommand(command.cmd));
    if (!dec.ok) {
      await vaultIngest(envelope("agent.capability.denied", {
        request_id: message.request_id,
        from,
        action: message.action,
        denied_reason: dec.reason,
      }));
      await vaultIngest(envelope("node.maintenance.result", {
        request_id: message.request_id,
        from,
        action: message.action,
        ok: false,
        result_summary: dec.reason,
      }));
      return;
    }
    await executeWithAudit({
      typeIntent: "node.maintenance.intent",
      typeResult: "node.maintenance.result",
      requestId: message.request_id,
      from,
      action: message.action,
      command,
      topic: message.topic,
    });
    return;
  }
  if (message.action.startsWith("panic.")) {
    await handlePanicAction(message, from);
    return;
  }
  if (message.action.startsWith("ritual.")) {
    await handleRitualAction(message, from);
    return;
  }
  if (message.action.startsWith("build.")) {
    await handleBuildAction(message, from);
    return;
  }
}

async function handleTopicMessage(topic, message, from) {
  if (topic === "ops.claim") {
    await handleClaimAction(message, from);
    return;
  }

  if (topic === "ops.flash") {
    await handleFlashAction(message, from);
    return;
  }

  if (topic === "ops.health.request") {
    if (!shouldHandleForScope(message)) return;
    await healthSnapshot("ops.health.request", { request_id: message.request_id, from });
    return;
  }

  if (["ops.maintenance", "ops.maint", "ops.snapshot", "ops.scan", "ops.build", "ops.ritual", "ops.panic"].includes(topic)) {
    await handleActionMessage(message, from);
    return;
  }

  if (topic === "god.button") {
    // New contract is router-based; only legacy op executes directly.
    if (message.op && !message.action) {
      const legacyAction = LEGACY_GOD_OP_MAP[String(message.op)] || "";
      if (legacyAction) {
        await handleActionMessage({ ...message, action: legacyAction }, from);
      }
    }
  }
}

async function connectRoom() {
  const token = await getToken();
  const room = new Room();

  room.on("dataReceived", async (payload, participant, _kind, topic) => {
    const from = participant?.identity || "unknown";
    let rawMsg = {};
    try {
      rawMsg = JSON.parse(new TextDecoder().decode(payload));
    } catch {
      rawMsg = {};
    }

    const message = normalizedActionMessage(topic, rawMsg);
    try {
      await handleTopicMessage(topic, message, from);
    } catch (err) {
      const error = String(err?.message || err);
      console.error(`handleTopicMessage failed topic=${topic} err=${error}`);
      try {
        await vaultIngest(envelope("agent.exec.result", {
          request_id: message.request_id,
          from,
          action: message.action,
          ok: false,
          error,
          topic,
        }));
      } catch {
        // fail-closed: do nothing else
      }
    }
  });

  await room.connect(LIVEKIT_URL, token);
  return room;
}

async function main() {
  if (!CAPS_STATE.valid) {
    console.warn(`capabilities invalid: ${CAPS_STATE.reason}; non-snapshot actions are disabled`);
  }
  process.on("SIGHUP", () => {
    CAPS_STATE = loadCapabilitiesState();
    if (!CAPS_STATE.valid) {
      console.warn(`capabilities reload invalid: ${CAPS_STATE.reason}; non-snapshot actions are disabled`);
      return;
    }
    console.log(`capabilities reloaded from ${CAPABILITIES_PATH}`);
  });

  const room = await connectRoom();
  console.log(`exec-agent connected: ${IDENTITY} room=${ROOM_NAME} node=${NODE_ID} device=${DEVICE_ID}`);

  if (HEALTH_INTERVAL_MS > 0) {
    setInterval(() => {
      healthSnapshot("interval").catch((e) => {
        console.error(`health snapshot failed: ${String(e?.message || e)}`);
      });
    }, HEALTH_INTERVAL_MS).unref();
  }

  room.on("disconnected", () => {
    process.exit(1);
  });
}

main().catch((e) => {
  console.error(e?.stack ?? String(e));
  process.exit(1);
});
