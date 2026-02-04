#!/usr/bin/env node
import { SODSServer } from "./server.js";
import { WebSocket } from "ws";
import { createWriteStream, existsSync, readFileSync, writeFileSync, mkdirSync, chmodSync } from "node:fs";
import { spawn } from "node:child_process";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { toolRegistryPaths, ToolEntry } from "./tool-registry.js";
import { presetRegistryPaths } from "./presets.js";

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
  tool add --entry <json> --script <path|->
  tool edit --entry <json> [--script <path|->]
  tool rm --name <tool_name>
  presets [--station <url>]
  preset run <preset_id> [--station <url>]
  preset add --preset <json>
  preset edit --preset <json>
  preset rm --id <preset_id>
  scratch --runner <shell|python|node> [--input <json>] < script

Defaults:
  --pi-logger http://pi-logger.local:8088
  --port 9123
  --station http://localhost:9123
  --logger http://pi-logger.local:8088
`);
  process.exit(exitCode);
}

if (hasFlag("--help") || cmd === "--help") {
  usage(0);
}
if (cmd === "help") {
  usage(0);
}

function repoRoot(): string {
  let dir = resolve(fileURLToPath(new URL(".", import.meta.url)));
  for (let i = 0; i < 6; i += 1) {
    const toolsPath = resolve(dir, "tools", "_sods_cli.sh");
    const cliPath = resolve(dir, "cli", "sods");
    if (existsSync(toolsPath) && existsSync(cliPath)) return dir;
    const parent = resolve(dir, "..");
    if (parent === dir) break;
    dir = parent;
  }
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

async function httpPost(path: string, payload: any) {
  const url = `${stationURL()}${path}`;
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  return res.json();
}

function isStationExplicit() {
  return args.includes("--station");
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
  const repoRoot = new URL("../../..", import.meta.url).pathname;
  const defaultLocalLog = `${repoRoot}/data/logs/local-events.ndjson`;
  const localLogPath = process.env.SODS_LOCAL_LOG_PATH ?? defaultLocalLog;
  const server = new SODSServer({
    port,
    piLoggerBase: piLogger,
    publicDir: new URL("../public/", import.meta.url).pathname,
    flashDir: new URL("../../../firmware/node-agent/esp-web-tools/", import.meta.url).pathname,
    portalFlashDir: new URL("../../../firmware/ops-portal/esp-web-tools/", import.meta.url).pathname,
    localLogPath: localLogPath && localLogPath.trim() ? localLogPath.trim() : undefined,
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

  const aliases = await fetchAliases();
  const alias = resolveAlias(aliases, nodeId, ip, parseJsonMaybe(match.data_json));
  const seenAt = new Date(eventTime(match)).toISOString();
  console.log(`node_id:   ${nodeId}`);
  if (alias) console.log(`alias:     ${alias}`);
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
  let data: any = {};
  for (const ev of events) {
    data = parseJsonMaybe(ev.data_json);
    ip = extractIp(data);
    if (ip) break;
  }

  if (!ip) {
    console.error("Node IP not found in recent events");
    process.exit(2);
  }

  const aliases = await fetchAliases();
  const alias = resolveAlias(aliases, nodeId, ip, data);
  if (alias) {
    console.log(`alias: ${alias}`);
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
  let aliases: Record<string, string> = {};
  let aliasFetchedAt = 0;
  while (true) {
    try {
      if (Date.now() - aliasFetchedAt > 60_000) {
        aliases = await fetchAliases();
        aliasFetchedAt = Date.now();
      }
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
        const alias = resolveAlias(aliases, nodeId, undefined, data);
        console.log(JSON.stringify({ ts, node_id: nodeId, alias, kind: ev.kind, summary, data }));
      }
    } catch (err: any) {
      console.error(err?.message ?? "tail error");
    }
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
}

async function fetchAliases(): Promise<Record<string, string>> {
  try {
    const res = await fetch(`${stationURL()}/api/aliases`, { method: "GET" });
    if (!res.ok) return {};
    const json = await res.json();
    return json.aliases ?? {};
  } catch {
    return {};
  }
}

function resolveAlias(
  aliases: Record<string, string>,
  nodeId: string | undefined,
  ip: string | undefined,
  data: any
): string | undefined {
  if (!aliases || Object.keys(aliases).length === 0) return undefined;
  const deviceId = data?.device_id ?? data?.deviceId ?? data?.device ?? data?.addr ?? data?.address ?? data?.mac ?? data?.mac_address ?? data?.bssid;
  const hostname = data?.hostname ?? data?.host;
  if (nodeId && aliases[`node:${nodeId}`]) return aliases[`node:${nodeId}`];
  if (nodeId && aliases[nodeId]) return aliases[nodeId];
  if (ip && aliases[ip]) return aliases[ip];
  if (deviceId && aliases[String(deviceId)]) return aliases[String(deviceId)];
  if (hostname && aliases[String(hostname)]) return aliases[String(hostname)];
  return undefined;
}

async function cmdTools() {
  const data = await httpJson("/api/tools");
  const items = data.tools ?? data.items ?? [];
  for (const tool of items) {
    console.log(`${tool.name}  runner=${tool.runner ?? "builtin"}  kind=${tool.kind ?? ""}`);
  }
}

async function cmdTool() {
  const name = positional(1);
  if (!name) return usage(1);
  const inputArg = getArg("--input") ?? "{}";
  let input = {};
  try { input = JSON.parse(inputArg); } catch { console.error("--input must be JSON"); process.exit(1); }
  const json = await httpPost("/api/tool/run", { name, input });
  console.log(JSON.stringify(json, null, 2));
}

async function cmdToolEdit(action: "add" | "update" | "delete") {
  const entryArg = getArg("--entry");
  const nameArg = getArg("--name");
  const scriptPath = getArg("--script");
  if (action === "delete") {
    if (!nameArg) return usage(1);
  } else if (!entryArg) {
    return usage(1);
  }
  const entry = entryArg ? parseJsonMaybe(entryArg) as ToolEntry : { name: nameArg } as ToolEntry;
  if (entryArg && !entry.name) {
    console.error("--entry must include name");
    process.exit(1);
  }
  const payload: any = { entry };
  if (scriptPath) {
    const content = scriptPath === "-" ? await readStdin() : readFileSync(scriptPath, "utf8");
    payload.script = content;
  }
  if (isStationExplicit()) {
    const path = action === "delete" ? "/api/tools/user/delete" : action === "add" ? "/api/tools/user/add" : "/api/tools/user/update";
    await httpPost(path, payload);
    console.log("ok");
    return;
  }
  writeUserTool(entry, payload.script, action);
  console.log("ok");
}

async function cmdPresets() {
  const data = await httpJson("/api/presets");
  const items = data.presets ?? [];
  for (const p of items) {
    console.log(`${p.id}  kind=${p.kind}`);
  }
}

async function cmdPresetRun() {
  const id = positional(2) ?? positional(1);
  if (!id) return usage(1);
  const json = await httpPost("/api/preset/run", { id });
  console.log(JSON.stringify(json, null, 2));
}

async function cmdPresetEdit(action: "add" | "update" | "delete") {
  if (action === "delete") {
    const id = getArg("--id");
    if (!id) return usage(1);
    if (isStationExplicit()) {
      await httpPost("/api/presets/user/delete", { preset: { id } });
      console.log("ok");
      return;
    }
    writeUserPreset({ id }, action);
    console.log("ok");
    return;
  }
  const presetArg = getArg("--preset");
  if (!presetArg) return usage(1);
  const preset = parseJsonMaybe(presetArg);
  if (!preset.id) {
    console.error("--preset must include id");
    process.exit(1);
  }
  if (isStationExplicit()) {
    const path = action === "add" ? "/api/presets/user/add" : "/api/presets/user/update";
    await httpPost(path, { preset });
    console.log("ok");
    return;
  }
  writeUserPreset(preset, action);
  console.log("ok");
}

async function cmdScratch() {
  const runner = getArg("--runner");
  if (!runner) return usage(1);
  const inputArg = getArg("--input") ?? "{}";
  const input = parseJsonMaybe(inputArg);
  const script = await readStdin();
  const json = await httpPost("/api/scratch/run", { runner, script, input });
  console.log(JSON.stringify(json, null, 2));
}

async function cmdAliasList() {
  const station = stationURL();
  if (!station) {
    console.error("Use --station for alias operations.");
    process.exit(1);
  }
  const res = await fetch(`${station}/api/aliases`, { method: "GET" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const json = await res.json();
  const aliases = json.aliases ?? {};
  console.log(JSON.stringify({ aliases }, null, 2));
}

async function cmdAliasEdit(action: "set" | "delete") {
  const station = stationURL();
  if (!station) {
    console.error("Use --station for alias operations.");
    process.exit(1);
  }
  const id = positional(2);
  if (!id) {
    console.error("alias id required");
    process.exit(1);
  }
  const alias = action === "set" ? positional(3) : undefined;
  if (action === "set" && !alias) {
    console.error("alias value required");
    process.exit(1);
  }
  const payload: Record<string, unknown> = { id };
  if (alias) payload.alias = alias;
  const path = action === "set" ? "/api/aliases/user/set" : "/api/aliases/user/delete";
  const res = await fetch(`${station}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log("ok");
}

async function cmdAliasExport() {
  await cmdAliasList();
}

async function cmdAliasImport() {
  const station = stationURL();
  if (!station) {
    console.error("Use --station for alias operations.");
    process.exit(1);
  }
  const raw = await readStdin();
  if (!raw) {
    console.error("Provide alias JSON on stdin.");
    process.exit(1);
  }
  const parsed = JSON.parse(raw);
  const aliases = parsed.aliases ?? parsed;
  for (const [id, alias] of Object.entries(aliases)) {
    const payload = { id, alias };
    await fetch(`${station}/api/aliases/user/set`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  }
  console.log("ok");
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf8");
}

function readUserRegistry() {
  const { userPath } = toolRegistryPaths();
  if (!existsSync(userPath)) return { tools: [] as ToolEntry[] };
  return JSON.parse(readFileSync(userPath, "utf8"));
}

function writeUserRegistry(tools: ToolEntry[]) {
  const { userPath } = toolRegistryPaths();
  writeFileSync(userPath, JSON.stringify({ version: "1.0", tools }, null, 2));
}

function writeUserTool(entry: ToolEntry, script: string | undefined, action: "add" | "update" | "delete") {
  const { repoRoot, userToolsDir } = toolRegistryPaths();
  mkdirSync(userToolsDir, { recursive: true });
  const registry = readUserRegistry();
  if (action === "delete") {
    registry.tools = registry.tools.filter((t: ToolEntry) => t.name !== entry.name);
    writeUserRegistry(registry.tools);
    return;
  }
  const ext = entry.runner === "python" ? "py" : entry.runner === "node" ? "mjs" : "sh";
  const safeName = entry.name.replace(/[^a-zA-Z0-9._-]/g, "_");
  const scriptRel = `tools/user/${safeName}.${ext}`;
  if (script) {
    const scriptAbs = resolve(join(repoRoot, scriptRel));
    writeFileSync(scriptAbs, script, "utf8");
    if (entry.runner === "shell") chmodSync(scriptAbs, 0o755);
  }
  entry.entry = scriptRel;
  registry.tools = registry.tools.filter((t: ToolEntry) => t.name !== entry.name);
  registry.tools.push(entry);
  writeUserRegistry(registry.tools);
}

function readUserPresets() {
  const { userPath } = presetRegistryPaths();
  if (!existsSync(userPath)) return { presets: [] as any[] };
  return JSON.parse(readFileSync(userPath, "utf8"));
}

function writeUserPresets(presets: any[]) {
  const { userPath } = presetRegistryPaths();
  writeFileSync(userPath, JSON.stringify({ version: "1.0", presets }, null, 2));
}

function writeUserPreset(preset: any, action: "add" | "update" | "delete") {
  const registry = readUserPresets();
  if (action === "delete") {
    registry.presets = registry.presets.filter((p: any) => p.id !== preset.id);
    writeUserPresets(registry.presets);
    return;
  }
  registry.presets = registry.presets.filter((p: any) => p.id !== preset.id);
  registry.presets.push(preset);
  writeUserPresets(registry.presets);
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
  child.on("error", (err) => {
    console.error(err.message);
    process.exit(2);
  });
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
  const sub = positional(1);
  if (sub === "add") {
    await cmdToolEdit("add");
  } else if (sub === "edit" || sub === "update") {
    await cmdToolEdit("update");
  } else if (sub === "rm" || sub === "delete") {
    await cmdToolEdit("delete");
  } else {
    await cmdTool();
  }
} else if (cmd === "presets") {
  await cmdPresets();
} else if (cmd === "preset") {
  const sub = positional(1);
  if (sub === "run") {
    await cmdPresetRun();
  } else if (sub === "add") {
    await cmdPresetEdit("add");
  } else if (sub === "edit" || sub === "update") {
    await cmdPresetEdit("update");
  } else if (sub === "rm" || sub === "delete") {
    await cmdPresetEdit("delete");
  } else {
    await cmdPresetRun();
  }
} else if (cmd === "scratch") {
  await cmdScratch();
} else if (cmd === "aliases" || cmd === "alias") {
  const sub = positional(1);
  if (sub === "add" || sub === "set") {
    await cmdAliasEdit("set");
  } else if (sub === "rm" || sub === "delete") {
    await cmdAliasEdit("delete");
  } else if (sub === "import") {
    await cmdAliasImport();
  } else if (sub === "export") {
    await cmdAliasExport();
  } else {
    await cmdAliasList();
  }
} else {
  usage(cmd === "help" ? 0 : 1);
}
