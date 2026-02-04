#!/usr/bin/env node
import { SODSServer } from "./server.js";
import { WebSocket } from "ws";
import { createWriteStream, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const cmd = args[0] ?? "help";

function getArg(flag: string, fallback?: string) {
  const idx = args.indexOf(flag);
  if (idx === -1) return fallback;
  const val = args[idx + 1];
  if (!val || val.startsWith("--")) return fallback;
  return val;
}

function hasFlag(flag: string) {
  return args.includes(flag);
}

function positional(index: number): string | undefined {
  const list = args.filter((a) => !a.startsWith("--"));
  return list[index];
}

function usage(exitCode = 0) {
  console.log(`sods <command> [options]

Commands:
  start --pi-logger <url> --port <port>
  whereis <node_id> [--logger <url>] [--limit <n>]
  open <node_id> [--logger <url>] [--limit <n>]
  spectrum [--station <url>]
  tail <node_id> [--logger <url>] [--limit <n>] [--interval <ms>]
  stream --frames [--station <url>] [--out <path>]
  wifi-scan [--pattern <regex>]
  tools [--station <url>]
  tool <name> [--station <url>] [--input <json>]

Defaults:
  --pi-logger http://pi-logger.local:8088
  --port 9123
  --station http://localhost:9123
  --logger http://pi-logger.local:8088
`);
  process.exit(exitCode);
}

function repoRoot(): string {
  return resolve(fileURLToPath(new URL("../../../..", import.meta.url)));
}

function stationURL() {
  return (getArg("--station", "http://localhost:9123") ?? "http://localhost:9123").replace(/\/+$/, "");
}

function loggerURL() {
  return (getArg("--logger", "http://pi-logger.local:8088") ?? "http://pi-logger.local:8088").replace(/\/+$/, "");
}

function parseJsonMaybe(value: any): Record<string, unknown> {
  if (value == null) return {};
  if (typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
    } catch {
      return {};
    }
  }
  return {};
}

function extractIp(data: Record<string, unknown>): string | undefined {
  const direct = pickString(data, ["ip", "ip_addr", "ip_address"]);
  if (direct) return direct;

  const wifi = parseJsonMaybe(data["wifi"]);
  const net = parseJsonMaybe(data["net"]);
  const sta = parseJsonMaybe(data["sta"]);

  const wifiIp = pickString(wifi, ["ip", "ip_addr", "ip_address"]);
  if (wifiIp) return wifiIp;

  const netIp = pickString(net, ["ip", "ip_addr", "ip_address"]);
  if (netIp) return netIp;

  const staIp = pickString(sta, ["ip", "ip_addr", "ip_address"]);
  if (staIp) return staIp;

  return undefined;
}

function pickString(data: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const val = data[key];
    if (typeof val === "string" && val.trim()) return val.trim();
  }
  return undefined;
}

type RawEvent = {
  id?: string | number;
  recv_ts?: string;
  event_ts?: string;
  node_id?: string;
  kind?: string;
  summary?: string;
  data_json?: any;
};

async function httpJson(path: string) {
  const url = `${stationURL()}${path}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

async function fetchEvents(nodeId: string, limit: number) {
  const url = new URL(`${loggerURL()}/v1/events`);
  url.searchParams.set("node_id", nodeId);
  url.searchParams.set("limit", String(limit));
  const res = await fetch(url, { headers: { "Accept": "application/json" } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = await res.json();
  const items: RawEvent[] = Array.isArray(body) ? body : body.items ?? body.events ?? [];
  return items.map((ev) => ({
    ...ev,
    data_json: parseJsonMaybe(ev.data_json),
  }));
}

function eventTime(ev: RawEvent): number {
  if (ev.event_ts) {
    const parsed = Date.parse(ev.event_ts);
    if (Number.isFinite(parsed)) return parsed;
  }
  if (ev.recv_ts) {
    const parsed = Date.parse(ev.recv_ts);
    if (Number.isFinite(parsed)) return parsed;
  }
  if (typeof ev.id === "number") return ev.id;
  return 0;
}

async function cmdStart() {
  const piLogger = getArg("--pi-logger", "http://pi-logger.local:8088")!;
  const port = Number(getArg("--port", "9123"));
  if (!piLogger.startsWith("http")) {
    console.error("Invalid --pi-logger URL");
    process.exit(1);
  }
  const server = new SODSServer({
    port,
    piLoggerBase: piLogger,
    publicDir: new URL("../public/", import.meta.url).pathname,
  });
  server.start();
  console.log(`sods running on http://localhost:${port}`);
}

async function cmdWhereis() {
  const nodeId = positional(1);
  if (!nodeId) return usage(1);
  const limit = Number(getArg("--limit", "200"));
  const events = await fetchEvents(nodeId, limit);
  events.sort((a, b) => eventTime(b) - eventTime(a));
  const preferredKinds = new Set(["wifi.status", "node.announce"]);

  let match: RawEvent | undefined;
  let ip: string | undefined;

  for (const ev of events) {
    const data = parseJsonMaybe(ev.data_json);
    const found = extractIp(data);
    if (!found) continue;
    if (preferredKinds.has(ev.kind ?? "")) {
      match = ev;
      ip = found;
      break;
    }
    if (!match) {
      match = ev;
      ip = found;
    }
  }

  if (!match || !ip) {
    console.error("Node IP not found in recent events");
    process.exit(2);
  }

  const seenAt = new Date(eventTime(match)).toISOString();
  console.log(`node_id:   ${nodeId}`);
  console.log(`ip:        ${ip}`);
  console.log(`kind:      ${match.kind ?? "?"}`);
  console.log(`last_seen: ${seenAt}`);
}

async function cmdOpen() {
  const nodeId = positional(1);
  if (!nodeId) return usage(1);
  const limit = Number(getArg("--limit", "200"));
  const events = await fetchEvents(nodeId, limit);
  events.sort((a, b) => eventTime(b) - eventTime(a));

  let ip: string | undefined;
  for (const ev of events) {
    const data = parseJsonMaybe(ev.data_json);
    ip = extractIp(data);
    if (ip) break;
  }

  if (!ip) {
    console.error("Node IP not found in recent events");
    process.exit(2);
  }

  const urls = [`http://${ip}/health`, `http://${ip}/metrics`, `http://${ip}/whoami`];
  for (const url of urls) {
    console.log(url);
    if (process.platform === "darwin") spawn("open", [url], { stdio: "ignore", detached: true }).unref();
  }
}

async function cmdSpectrum() {
  const url = `${stationURL()}/`;
  console.log(url);
  if (process.platform === "darwin") spawn("open", [url], { stdio: "ignore", detached: true }).unref();
}

async function cmdTail() {
  const nodeId = positional(1);
  if (!nodeId) return usage(1);
  const limit = Number(getArg("--limit", "200"));
  const interval = Number(getArg("--interval", "1200"));
  const seen = new Set<string>();
  while (true) {
    try {
      const events = await fetchEvents(nodeId, limit);
      events.sort((a, b) => eventTime(a) - eventTime(b));
      for (const ev of events) {
        const id = ev.id != null ? String(ev.id) : `${eventTime(ev)}:${ev.kind ?? "unknown"}`;
        if (seen.has(id)) continue;
        seen.add(id);
        if (seen.size > 4000) {
          const keep = Array.from(seen).slice(-2000);
          seen.clear();
          for (const k of keep) seen.add(k);
        }
        const ts = new Date(eventTime(ev)).toISOString();
        const data = parseJsonMaybe(ev.data_json);
        const summary = ev.summary ?? ev.kind ?? "event";
        console.log(JSON.stringify({ ts, node_id: nodeId, kind: ev.kind, summary, data }));
      }
    } catch (err: any) {
      console.error(err?.message ?? "tail error");
    }
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
}

async function cmdTools() {
  const data = await httpJson("/tools");
  const items = data.items ?? [];
  for (const tool of items) {
    console.log(`${tool.name}  scope=${tool.scope}  input=${tool.input}  output=${tool.output}  kind=${tool.kind}`);
  }
}

async function cmdTool() {
  const name = positional(1);
  if (!name) return usage(1);
  const inputArg = getArg("--input") ?? "{}";
  let input = {};
  try { input = JSON.parse(inputArg); } catch { console.error("--input must be JSON"); process.exit(1); }
  const res = await fetch(`${stationURL()}/tools/run`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, input }) });
  if (!res.ok) {
    console.error(`HTTP ${res.status}`);
    console.error(await res.text());
    process.exit(2);
  }
  const json = await res.json();
  console.log(JSON.stringify(json, null, 2));
}

async function cmdStream() {
  if (!hasFlag("--frames")) return usage(1);
  const wsURL = stationURL().replace(/^http/, "ws") + "/ws/frames";
  const outPath = getArg("--out") ?? "";
  const out = outPath ? createWriteStream(outPath) : null;
  const ws = new WebSocket(wsURL);
  ws.on("message", (data) => {
    const line = String(data);
    if (out) {
      out.write(line + "\n");
    } else {
      process.stdout.write(line + "\n");
    }
  });
  ws.on("error", (err) => {
    console.error(err.message);
    process.exit(2);
  });
}

async function cmdWifiScan() {
  const pattern = getArg("--pattern", "") ?? "";
  const script = resolve(repoRoot(), "tools/wifi-scan.sh");
  if (!existsSync(script)) {
    console.error(`wifi-scan helper not found at ${script}`);
    process.exit(2);
  }
  const child = spawn(script, pattern ? [pattern] : [], { stdio: "inherit" });
  child.on("exit", (code) => process.exit(code ?? 1));
}

if (cmd === "start") {
  await cmdStart();
} else if (cmd === "whereis") {
  await cmdWhereis();
} else if (cmd === "open") {
  await cmdOpen();
} else if (cmd === "spectrum") {
  await cmdSpectrum();
} else if (cmd === "tail") {
  await cmdTail();
} else if (cmd === "stream") {
  await cmdStream();
} else if (cmd === "wifi-scan") {
  await cmdWifiScan();
} else if (cmd === "tools") {
  await cmdTools();
} else if (cmd === "tool") {
  await cmdTool();
} else {
  usage(cmd === "help" ? 0 : 1);
}
