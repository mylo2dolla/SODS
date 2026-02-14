import express from "express";
import fs from "node:fs";
import path from "node:path";
import { spawnSync, execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

function readEnvInt(name, fallback, min, max) {
  const raw = Number(process.env[name] ?? fallback);
  if (!Number.isFinite(raw)) return fallback;
  const rounded = Math.floor(raw);
  return Math.max(min, Math.min(max, rounded));
}

const HOST = process.env.HOST || "0.0.0.0";
const PORT = Number(process.env.PORT || 9101);
const READ_MODE = String(process.env.READ_MODE || "auto").trim();
const READ_TIMEOUT_MS = readEnvInt("OPS_FEED_READ_TIMEOUT_MS", 6_000, 500, 30_000);
const HEALTH_CACHE_MS = readEnvInt("OPS_FEED_HEALTH_CACHE_MS", 5_000, 1_000, 60_000);
const SSH_CONNECT_TIMEOUT_S = readEnvInt("OPS_FEED_SSH_CONNECT_TIMEOUT_S", 5, 1, 30);
const SSH_RETRIES = readEnvInt("OPS_FEED_SSH_RETRIES", 1, 0, 5);

const VAULT_EVENTS_DIR = process.env.VAULT_EVENTS_DIR || "/vault/sods/vault/events";
const LOGGER_HOST = process.env.LOGGER_HOST || "pi-logger.local";
const REMOTE_HOST = process.env.REMOTE_HOST || `pi@${LOGGER_HOST}`;
const REMOTE_EVENTS_DIR = process.env.REMOTE_EVENTS_DIR || "/vault/sods/vault/events";
const SSH_BIN = process.env.SSH_BIN || "ssh";

const SL_SSH_BIN = process.env.SL_SSH_BIN || "/usr/local/bin/sl-ssh";
const SL_SSH_ALIAS = process.env.SL_SSH_ALIAS || "vault";

const MAX_LIMIT = 500;
const DEFAULT_LIMIT = 200;
const MAX_WINDOW_MS = 24 * 60 * 60 * 1000;
const MAX_TAIL_LINES = 8_000;
const DEFAULT_TAIL_LINES = 200;
const MAX_TAIL_LINES_PER_FILE = 400;

const app = express();

function hasExecutable(binPath) {
  try {
    const out = spawnSync("/bin/sh", ["-lc", `command -v '${binPath.replace(/'/g, "'\\''")}'`], { encoding: "utf8", timeout: 2_000 });
    return out.status === 0 && String(out.stdout || "").trim().length > 0;
  } catch {
    return false;
  }
}

function resolveReadMode() {
  const mode = READ_MODE.toLowerCase();
  if (mode === "local" || mode === "ssh" || mode === "ssh_guard") return mode;
  if (mode === "auto") {
    if (hasExecutable(SL_SSH_BIN)) return "ssh_guard";
    return "ssh";
  }
  throw new Error(`unsupported READ_MODE: ${READ_MODE}`);
}

const EFFECTIVE_READ_MODE = resolveReadMode();

function nowMs() {
  return Date.now();
}

function clampInt(value, min, max, fallback) {
  const num = Number(value);
  if (!Number.isFinite(num)) return fallback;
  const rounded = Math.floor(num);
  return Math.max(min, Math.min(max, rounded));
}

function parseJsonLine(line) {
  try {
    const obj = JSON.parse(line);
    if (!obj || typeof obj !== "object") return null;
    return obj;
  } catch {
    return null;
  }
}

function normalizeTsMs(event) {
  const ts = Number(event?.ts_ms);
  return Number.isFinite(ts) ? ts : 0;
}

function dayDirValid(name) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(name || ""));
}

function sortedRecentDayDirs(dayDirs, cutoffMs) {
  const cutoffDate = new Date(cutoffMs);
  const minName = `${cutoffDate.getUTCFullYear()}-${String(cutoffDate.getUTCMonth() + 1).padStart(2, "0")}-${String(cutoffDate.getUTCDate()).padStart(2, "0")}`;
  return dayDirs
    .filter((name) => dayDirValid(name) && name >= minName)
    .sort()
    .reverse();
}

async function runLocal(cmd, args) {
  try {
    const { stdout } = await execFileAsync(cmd, args, {
      encoding: "utf8",
      timeout: READ_TIMEOUT_MS,
      maxBuffer: 8 * 1024 * 1024,
    });
    return stdout || "";
  } catch (error) {
    const stderr = String(error?.stderr || "").trim();
    const stdout = String(error?.stdout || "").trim();
    throw new Error(stderr || stdout || `${cmd} failed`);
  }
}

async function runRemoteSsh(cmd, args) {
  const remote = [cmd, ...args].map((part) => `'${String(part).replace(/'/g, "'\\''")}'`).join(" ");
  try {
    const { stdout } = await execFileAsync(
      SSH_BIN,
      ["-o", "BatchMode=yes", "-o", `ConnectTimeout=${SSH_CONNECT_TIMEOUT_S}`, REMOTE_HOST, remote],
      { encoding: "utf8", timeout: READ_TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024 },
    );
    return stdout || "";
  } catch (error) {
    const stderr = String(error?.stderr || "").trim();
    const stdout = String(error?.stdout || "").trim();
    const stdoutHead = stdout.length > 220 ? `${stdout.slice(0, 220)}...` : stdout;
    const status = typeof error?.code === "number" ? ` status=${String(error.code)}` : "";
    throw new Error(stderr || `ssh command failed: ${cmd}${status} stdout=${stdoutHead}`);
  }
}

async function runRemoteGuarded(cmd, args) {
  const requestId = `ops-feed-${randomUUID()}`;
  try {
    const { stdout } = await execFileAsync(
      SL_SSH_BIN,
      [SL_SSH_ALIAS, requestId, cmd, ...args],
      { encoding: "utf8", timeout: READ_TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024 },
    );
    const payload = parseJsonLine((stdout || "").trim());
    if (!payload || payload.ok !== true) {
      throw new Error(`sl-ssh response invalid for ${cmd}`);
    }
    return String(payload.stdout || "");
  } catch (error) {
    const stderr = String(error?.stderr || "").trim();
    const stdout = String(error?.stdout || "").trim();
    const stdoutHead = stdout.length > 220 ? `${stdout.slice(0, 220)}...` : stdout;
    const status = typeof error?.code === "number" ? ` status=${String(error.code)}` : "";
    throw new Error(stderr || `sl-ssh command failed: ${cmd}${status} stdout=${stdoutHead}`);
  }
}

function isTransientReaderError(error) {
  const message = String(error?.message || error || "").toLowerCase();
  if (!message) return false;
  return message.includes("status=255")
    || message.includes("timed out")
    || message.includes("timeout")
    || message.includes("operation was aborted")
    || message.includes("connection reset")
    || message.includes("connection refused")
    || message.includes("broken pipe");
}

async function runReaderCommand(cmd, args) {
  if (EFFECTIVE_READ_MODE === "local") {
    return runLocal(cmd, args);
  }
  let runner = null;
  if (EFFECTIVE_READ_MODE === "ssh") {
    runner = runRemoteSsh;
  } else if (EFFECTIVE_READ_MODE === "ssh_guard") {
    runner = runRemoteGuarded;
  }
  if (!runner) throw new Error(`unsupported READ_MODE: ${EFFECTIVE_READ_MODE}`);

  let lastError = null;
  for (let attempt = 0; attempt <= SSH_RETRIES; attempt += 1) {
    try {
      return await runner(cmd, args);
    } catch (error) {
      lastError = error;
      if (attempt >= SSH_RETRIES || !isTransientReaderError(error)) {
        throw error;
      }
    }
  }
  if (lastError) throw lastError;
  throw new Error(`unsupported READ_MODE: ${EFFECTIVE_READ_MODE}`);
}

async function listDayDirs() {
  if (EFFECTIVE_READ_MODE === "local") {
    if (!fs.existsSync(VAULT_EVENTS_DIR)) return [];
    return fs.readdirSync(VAULT_EVENTS_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  }
  const root = REMOTE_EVENTS_DIR;
  const output = await runReaderCommand("/bin/ls", ["-1", root]);
  return output.split(/\r?\n/).map((v) => v.trim()).filter(Boolean);
}

function filePathForDay(dayName) {
  if (EFFECTIVE_READ_MODE === "local") {
    return path.join(VAULT_EVENTS_DIR, dayName, "ingest.ndjson");
  }
  return `${REMOTE_EVENTS_DIR}/${dayName}/ingest.ndjson`;
}

async function fileExists(filePath) {
  if (EFFECTIVE_READ_MODE === "local") {
    return fs.existsSync(filePath);
  }
  try {
    await runReaderCommand("/bin/ls", ["-1", filePath]);
    return true;
  } catch {
    return false;
  }
}

async function readTail(filePath, lines) {
  const bounded = clampInt(lines, 10, MAX_TAIL_LINES, DEFAULT_TAIL_LINES);
  const output = await runReaderCommand("/usr/bin/tail", ["-n", String(bounded), filePath]);
  return output.split(/\r?\n/).filter(Boolean);
}

function isIgnorableReadError(error) {
  const message = String(error?.message || error || "").toLowerCase();
  if (!message) return false;
  return isTransientReaderError(error)
    || message.includes("no such file or directory")
    || message.includes("cannot access")
    || message.includes("not found");
}

function matchesFilters(event, filters) {
  const ts = normalizeTsMs(event);
  if (ts < filters.sinceMs) return false;
  if (filters.typePrefix && !String(event.type || "").startsWith(filters.typePrefix)) return false;
  if (filters.src && String(event.src || "") !== filters.src) return false;
  return true;
}

async function readRecentEvents({ limit, sinceMs, typePrefix = "", src = "" }) {
  const filters = {
    sinceMs: Math.max(sinceMs, nowMs() - MAX_WINDOW_MS),
    typePrefix,
    src,
  };

  const dayDirs = sortedRecentDayDirs(await listDayDirs(), filters.sinceMs);
  const events = [];
  let malformed = 0;
  let readErrors = 0;

  for (const day of dayDirs) {
    const filePath = filePathForDay(day);
    if (!(await fileExists(filePath))) continue;
    const tailLines = Math.min(MAX_TAIL_LINES_PER_FILE, Math.max(DEFAULT_TAIL_LINES, limit * 2));
    let lines = [];
    try {
      lines = await readTail(filePath, tailLines);
    } catch (error) {
      if (isIgnorableReadError(error)) {
        readErrors += 1;
        continue;
      }
      throw error;
    }
    for (const line of lines) {
      const parsed = parseJsonLine(line);
      if (!parsed) {
        malformed += 1;
        continue;
      }
      if (!matchesFilters(parsed, filters)) continue;
      events.push(parsed);
    }
  }

  events.sort((a, b) => normalizeTsMs(b) - normalizeTsMs(a));
  return {
    malformed,
    read_errors: readErrors,
    events: events.slice(0, limit),
  };
}

function eventRequestId(event) {
  const top = event?.request_id;
  if (typeof top === "string" && top.length > 0) return top;
  const dataReq = event?.data?.request_id;
  if (typeof dataReq === "string" && dataReq.length > 0) return dataReq;
  const nestedReq = event?.data?.request?.request_id;
  if (typeof nestedReq === "string" && nestedReq.length > 0) return nestedReq;
  const dataRequestId = event?.data?.requestId;
  if (typeof dataRequestId === "string" && dataRequestId.length > 0) return dataRequestId;
  return "";
}

function summarizeNodeCounts(events) {
  const nodes = new Map();
  for (const event of events) {
    const src = String(event?.src || "");
    if (!src) continue;
    const type = String(event?.type || "unknown");
    const typePrefix = type.includes(".") ? type.split(".")[0] : type;
    const ts = normalizeTsMs(event);
    const existing = nodes.get(src) || {
      src,
      last_seen_ts_ms: 0,
      counts: {},
    };
    if (ts > existing.last_seen_ts_ms) {
      existing.last_seen_ts_ms = ts;
    }
    existing.counts[typePrefix] = Number(existing.counts[typePrefix] || 0) + 1;
    nodes.set(src, existing);
  }
  return Array.from(nodes.values()).sort((a, b) => b.last_seen_ts_ms - a.last_seen_ts_ms);
}

const sourceProbe = {
  ok: false,
  error: "not_checked",
  dayDirsVisible: 0,
  checkedAtMs: 0,
};
let sourceProbeRefreshing = false;

async function refreshSourceProbe() {
  if (sourceProbeRefreshing) return;
  sourceProbeRefreshing = true;
  const checkedAtMs = nowMs();
  try {
    const days = await listDayDirs();
    sourceProbe.ok = true;
    sourceProbe.error = "";
    sourceProbe.dayDirsVisible = days.length;
    sourceProbe.checkedAtMs = checkedAtMs;
  } catch (error) {
    sourceProbe.ok = false;
    sourceProbe.error = String(error?.message || error);
    sourceProbe.dayDirsVisible = 0;
    sourceProbe.checkedAtMs = checkedAtMs;
  } finally {
    sourceProbeRefreshing = false;
  }
}

function sourceProbePayload() {
  return {
    source_ok: sourceProbe.ok,
    source_error: sourceProbe.ok ? "" : sourceProbe.error,
    day_dirs_visible: sourceProbe.dayDirsVisible,
    source_checked_at_ms: sourceProbe.checkedAtMs,
  };
}

app.get("/health", (_req, res) => {
  return res.json({
    ok: true,
    service: "ops-feed",
    ts_ms: nowMs(),
    read_mode: EFFECTIVE_READ_MODE,
    source_root: EFFECTIVE_READ_MODE === "local" ? VAULT_EVENTS_DIR : REMOTE_EVENTS_DIR,
    ...sourceProbePayload(),
  });
});

app.get("/ready", (_req, res) => {
  const payload = {
    service: "ops-feed",
    ts_ms: nowMs(),
    read_mode: EFFECTIVE_READ_MODE,
    source_root: EFFECTIVE_READ_MODE === "local" ? VAULT_EVENTS_DIR : REMOTE_EVENTS_DIR,
    ...sourceProbePayload(),
  };
  if (sourceProbe.ok) {
    return res.json({ ok: true, ...payload });
  }
  return res.status(503).json({ ok: false, ...payload });
});

app.get("/events", async (req, res) => {
  try {
    const limit = clampInt(req.query.limit, 1, MAX_LIMIT, DEFAULT_LIMIT);
    const sinceMs = clampInt(req.query.since_ms, 0, nowMs(), nowMs() - 60 * 60 * 1000);
    const typePrefix = String(req.query.typePrefix || "");
    const src = String(req.query.src || "");
    const result = await readRecentEvents({ limit, sinceMs, typePrefix, src });
    return res.json({
      ok: true,
      count: result.events.length,
      malformed_lines_skipped: result.malformed,
      read_errors_skipped: result.read_errors,
      events: result.events,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.get("/trace", async (req, res) => {
  try {
    const requestId = String(req.query.request_id || "").trim();
    if (!requestId) {
      return res.status(400).json({ ok: false, error: "request_id is required" });
    }
    const limit = clampInt(req.query.limit, 1, MAX_LIMIT, DEFAULT_LIMIT);
    const sinceMs = clampInt(req.query.since_ms, 0, nowMs(), nowMs() - 60 * 60 * 1000);
    const scanLimit = clampInt(req.query.scan_limit, limit, MAX_LIMIT, Math.min(MAX_LIMIT, Math.max(DEFAULT_LIMIT, limit * 3)));
    const base = await readRecentEvents({ limit: scanLimit, sinceMs });
    const matched = base.events.filter((event) => eventRequestId(event) === requestId).slice(0, limit);
    return res.json({
      ok: true,
      request_id: requestId,
      count: matched.length,
      read_errors_skipped: base.read_errors,
      events: matched,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.get("/nodes", async (req, res) => {
  try {
    const windowS = clampInt(req.query.window_s, 10, 24 * 60 * 60, 120);
    const sinceMs = nowMs() - windowS * 1_000;
    const base = await readRecentEvents({ limit: MAX_LIMIT, sinceMs });
    const nodes = summarizeNodeCounts(base.events);
    return res.json({
      ok: true,
      window_s: windowS,
      read_errors_skipped: base.read_errors,
      nodes,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

void refreshSourceProbe();
const probeInterval = setInterval(() => {
  void refreshSourceProbe();
}, HEALTH_CACHE_MS);
if (typeof probeInterval.unref === "function") {
  probeInterval.unref();
}

app.listen(PORT, HOST, () => {
  console.log(`ops-feed listening on http://${HOST}:${PORT} mode=${EFFECTIVE_READ_MODE}`);
});
