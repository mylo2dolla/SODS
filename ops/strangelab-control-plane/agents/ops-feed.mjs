import express from "express";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";

const HOST = process.env.HOST || "0.0.0.0";
const PORT = Number(process.env.PORT || 9101);
const READ_MODE = String(process.env.READ_MODE || "auto").trim();

const VAULT_EVENTS_DIR = process.env.VAULT_EVENTS_DIR || "/var/sods/vault/events";
const LOGGER_HOST = process.env.LOGGER_HOST || "192.168.8.160";
const REMOTE_HOST = process.env.REMOTE_HOST || `pi@${LOGGER_HOST}`;
const REMOTE_EVENTS_DIR = process.env.REMOTE_EVENTS_DIR || "/var/sods/vault/events";
const SSH_BIN = process.env.SSH_BIN || "ssh";

const SL_SSH_BIN = process.env.SL_SSH_BIN || "/usr/local/bin/sl-ssh";
const SL_SSH_ALIAS = process.env.SL_SSH_ALIAS || "strangelab-pi-logger";

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

function runLocal(cmd, args) {
  const out = spawnSync(cmd, args, { encoding: "utf8", timeout: 12_000 });
  if (out.status !== 0) {
    throw new Error(out.stderr?.trim() || out.stdout?.trim() || `${cmd} failed`);
  }
  return out.stdout || "";
}

function runRemoteSsh(cmd, args) {
  const remote = [cmd, ...args].map((part) => `'${String(part).replace(/'/g, "'\\''")}'`).join(" ");
  const out = spawnSync(SSH_BIN, ["-o", "BatchMode=yes", REMOTE_HOST, remote], { encoding: "utf8", timeout: 45_000 });
  if (out.status !== 0) {
    const stderr = String(out.stderr || "").trim();
    const stdout = String(out.stdout || "").trim();
    const stdoutHead = stdout.length > 220 ? `${stdout.slice(0, 220)}...` : stdout;
    throw new Error(stderr || `ssh command failed: ${cmd} status=${String(out.status)} stdout=${stdoutHead}`);
  }
  return out.stdout || "";
}

function runRemoteGuarded(cmd, args) {
  const requestId = `ops-feed-${randomUUID()}`;
  const out = spawnSync(SL_SSH_BIN, [SL_SSH_ALIAS, requestId, cmd, ...args], { encoding: "utf8", timeout: 45_000 });
  if (out.status !== 0) {
    const stderr = String(out.stderr || "").trim();
    const stdout = String(out.stdout || "").trim();
    const stdoutHead = stdout.length > 220 ? `${stdout.slice(0, 220)}...` : stdout;
    throw new Error(stderr || `sl-ssh command failed: ${cmd} status=${String(out.status)} stdout=${stdoutHead}`);
  }
  const payload = parseJsonLine((out.stdout || "").trim());
  if (!payload || payload.ok !== true) {
    throw new Error(`sl-ssh response invalid for ${cmd}`);
  }
  return String(payload.stdout || "");
}

function runReaderCommand(cmd, args) {
  if (EFFECTIVE_READ_MODE === "local") {
    return runLocal(cmd, args);
  }
  if (EFFECTIVE_READ_MODE === "ssh") {
    return runRemoteSsh(cmd, args);
  }
  if (EFFECTIVE_READ_MODE === "ssh_guard") {
    return runRemoteGuarded(cmd, args);
  }
  throw new Error(`unsupported READ_MODE: ${EFFECTIVE_READ_MODE}`);
}

function listDayDirs() {
  if (EFFECTIVE_READ_MODE === "local") {
    if (!fs.existsSync(VAULT_EVENTS_DIR)) return [];
    return fs.readdirSync(VAULT_EVENTS_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  }
  const root = REMOTE_EVENTS_DIR;
  const output = runReaderCommand("/bin/ls", ["-1", root]);
  return output.split(/\r?\n/).map((v) => v.trim()).filter(Boolean);
}

function filePathForDay(dayName) {
  if (EFFECTIVE_READ_MODE === "local") {
    return path.join(VAULT_EVENTS_DIR, dayName, "ingest.ndjson");
  }
  return `${REMOTE_EVENTS_DIR}/${dayName}/ingest.ndjson`;
}

function fileExists(filePath) {
  if (EFFECTIVE_READ_MODE === "local") {
    return fs.existsSync(filePath);
  }
  try {
    runReaderCommand("/bin/ls", ["-1", filePath]);
    return true;
  } catch {
    return false;
  }
}

function readTail(filePath, lines) {
  const bounded = clampInt(lines, 10, MAX_TAIL_LINES, DEFAULT_TAIL_LINES);
  const output = runReaderCommand("/usr/bin/tail", ["-n", String(bounded), filePath]);
  return output.split(/\r?\n/).filter(Boolean);
}

function matchesFilters(event, filters) {
  const ts = normalizeTsMs(event);
  if (ts < filters.sinceMs) return false;
  if (filters.typePrefix && !String(event.type || "").startsWith(filters.typePrefix)) return false;
  if (filters.src && String(event.src || "") !== filters.src) return false;
  return true;
}

function readRecentEvents({ limit, sinceMs, typePrefix = "", src = "" }) {
  const filters = {
    sinceMs: Math.max(sinceMs, nowMs() - MAX_WINDOW_MS),
    typePrefix,
    src,
  };

  const dayDirs = sortedRecentDayDirs(listDayDirs(), filters.sinceMs);
  const events = [];
  let malformed = 0;

  for (const day of dayDirs) {
    const filePath = filePathForDay(day);
    if (!fileExists(filePath)) continue;
    const tailLines = Math.min(MAX_TAIL_LINES_PER_FILE, Math.max(DEFAULT_TAIL_LINES, limit * 2));
    const lines = readTail(filePath, tailLines);
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

app.get("/health", (_req, res) => {
  try {
    const days = listDayDirs();
    return res.json({
      ok: true,
      service: "ops-feed",
      ts_ms: nowMs(),
      read_mode: EFFECTIVE_READ_MODE,
      source_root: EFFECTIVE_READ_MODE === "local" ? VAULT_EVENTS_DIR : REMOTE_EVENTS_DIR,
      day_dirs_visible: days.length,
    });
  } catch (error) {
    return res.status(503).json({
      ok: false,
      service: "ops-feed",
      ts_ms: nowMs(),
      read_mode: EFFECTIVE_READ_MODE,
      error: String(error?.message || error),
    });
  }
});

app.get("/events", (req, res) => {
  try {
    const limit = clampInt(req.query.limit, 1, MAX_LIMIT, DEFAULT_LIMIT);
    const sinceMs = clampInt(req.query.since_ms, 0, nowMs(), nowMs() - 60 * 60 * 1000);
    const typePrefix = String(req.query.typePrefix || "");
    const src = String(req.query.src || "");
    const result = readRecentEvents({ limit, sinceMs, typePrefix, src });
    return res.json({
      ok: true,
      count: result.events.length,
      malformed_lines_skipped: result.malformed,
      events: result.events,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.get("/trace", (req, res) => {
  try {
    const requestId = String(req.query.request_id || "").trim();
    if (!requestId) {
      return res.status(400).json({ ok: false, error: "request_id is required" });
    }
    const limit = clampInt(req.query.limit, 1, MAX_LIMIT, DEFAULT_LIMIT);
    const sinceMs = clampInt(req.query.since_ms, 0, nowMs(), nowMs() - 60 * 60 * 1000);
    const scanLimit = clampInt(req.query.scan_limit, limit, MAX_LIMIT, Math.min(MAX_LIMIT, Math.max(DEFAULT_LIMIT, limit * 3)));
    const base = readRecentEvents({ limit: scanLimit, sinceMs });
    const matched = base.events.filter((event) => eventRequestId(event) === requestId).slice(0, limit);
    return res.json({
      ok: true,
      request_id: requestId,
      count: matched.length,
      events: matched,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.get("/nodes", (req, res) => {
  try {
    const windowS = clampInt(req.query.window_s, 10, 24 * 60 * 60, 120);
    const sinceMs = nowMs() - windowS * 1_000;
    const base = readRecentEvents({ limit: MAX_LIMIT, sinceMs });
    const nodes = summarizeNodeCounts(base.events);
    return res.json({
      ok: true,
      window_s: windowS,
      nodes,
    });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.listen(PORT, HOST, () => {
  console.log(`ops-feed listening on http://${HOST}:${PORT} mode=${EFFECTIVE_READ_MODE}`);
});
