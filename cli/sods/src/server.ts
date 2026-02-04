import http from "node:http";
import { readFileSync, existsSync, statSync, createReadStream, mkdirSync, createWriteStream, writeFileSync, chmodSync } from "node:fs";
import { join, resolve } from "node:path";
import { WebSocketServer, WebSocket } from "ws";
import { Ingestor } from "./ingest.js";
import { FrameEngine } from "./frame-engine.js";
import { CanonicalEvent, SignalFrame } from "./schema.js";
import { nowMs } from "./util.js";
import { listTools, runTool } from "./tools.js";
import { loadToolRegistry, ToolEntry } from "./tool-registry.js";
import { loadPresets, presetRegistryPaths } from "./presets.js";
import { runScriptTool, runScratch, RunResult as ToolRunResult } from "./tool-runner.js";
import { runPreset } from "./preset-runner.js";
import { toolRegistryPaths } from "./tool-registry.js";

type ServerOptions = {
  port: number;
  piLoggerBase: string;
  publicDir: string;
  flashDir: string;
  portalFlashDir?: string;
  localLogPath?: string;
};

export class SODSServer {
  private ingestor: Ingestor;
  private frameEngine = new FrameEngine(30);
  private lastEvent?: CanonicalEvent;
  private eventBuffer: CanonicalEvent[] = [];
  private lastFrames: SignalFrame[] = [];
  private lastError: string | null = null;
  private lastIngestAt = 0;
  private eventsClients: Set<WebSocket> = new Set();
  private frameClients: Set<WebSocket> = new Set();
  private server?: http.Server;
  private wssEvents?: WebSocketServer;
  private wssFrames?: WebSocketServer;
  private frameTimer?: NodeJS.Timeout;
  private localLogStream?: ReturnType<typeof createWriteStream>;

  constructor(private options: ServerOptions) {
    this.ingestor = new Ingestor(options.piLoggerBase, 500, 1400);
    if (options.localLogPath) {
      try {
        const dir = resolve(options.localLogPath, "..");
        mkdirSync(dir, { recursive: true });
        this.localLogStream = createWriteStream(options.localLogPath, { flags: "a" });
      } catch {
        this.localLogStream = undefined;
      }
    }
  }

  start() {
    this.server = http.createServer(this.handleRequest.bind(this));
    this.server.listen(this.options.port);

    this.wssEvents = new WebSocketServer({ noServer: true });
    this.wssFrames = new WebSocketServer({ noServer: true });

    this.server.on("upgrade", (req, socket, head) => {
      const url = req.url ?? "";
      if (url.startsWith("/ws/events")) {
        this.wssEvents?.handleUpgrade(req, socket, head, (ws) => {
          this.eventsClients.add(ws);
          ws.on("close", () => this.eventsClients.delete(ws));
        });
        return;
      }
      if (url.startsWith("/ws/frames")) {
        this.wssFrames?.handleUpgrade(req, socket, head, (ws) => {
          this.frameClients.add(ws);
          ws.on("close", () => this.frameClients.delete(ws));
        });
        return;
      }
      socket.destroy();
    });

    this.ingestor.start(
      (ev) => this.handleEvent(ev),
      (msg) => { this.lastError = msg; }
    );

    this.frameTimer = setInterval(() => this.emitFrames(), 1000 / 30);
  }

  stop() {
    this.ingestor.stop();
    if (this.frameTimer) clearInterval(this.frameTimer);
    if (this.localLogStream) this.localLogStream.end();
    this.server?.close();
  }

  private handleEvent(ev: CanonicalEvent) {
    this.lastEvent = ev;
    this.lastIngestAt = nowMs();
    this.frameEngine.ingest(ev);
    this.eventBuffer.push(ev);
    if (this.eventBuffer.length > 2000) this.eventBuffer.splice(0, this.eventBuffer.length - 2000);
    const payload = JSON.stringify(ev);
    for (const ws of this.eventsClients) {
      ws.send(payload);
    }
    if (this.localLogStream) {
      this.localLogStream.write(payload + "\n");
    }
  }

  private emitFrames() {
    const frames = this.frameEngine.tick();
    if (frames.length === 0) return;
    this.lastFrames = frames;
    const payload = JSON.stringify({ t: nowMs(), frames });
    for (const ws of this.frameClients) {
      ws.send(payload);
    }
  }

  private handleRequest(req: http.IncomingMessage, res: http.ServerResponse) {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    if (url.pathname === "/api/status") {
      void this.handleStatus(res);
      return;
    }
    if (url.pathname === "/api/portal/state") {
      void this.handlePortalState(req, res);
      return;
    }
    if (url.pathname === "/api/tools") {
      return this.respondJson(res, this.buildToolRegistry());
    }
    if (url.pathname === "/api/presets") {
      return this.respondJson(res, this.buildPresets());
    }
    if (url.pathname === "/api/preset/run" && req.method === "POST") {
      return this.handlePresetRun(req, res);
    }
    if (url.pathname === "/api/scratch/run" && req.method === "POST") {
      return this.handleScratchRun(req, res);
    }
    if (url.pathname.startsWith("/api/tools/user/")) {
      return this.handleUserToolEdit(req, res, url.pathname);
    }
    if (url.pathname.startsWith("/api/presets/user/")) {
      return this.handleUserPresetEdit(req, res, url.pathname);
    }
    if (url.pathname.startsWith("/api/aliases/user/")) {
      return this.handleUserAliasEdit(req, res, url.pathname);
    }
    if (url.pathname === "/api/aliases") {
      return this.respondJson(res, { aliases: this.readAliases() });
    }
    if (url.pathname === "/health") {
      const counters = this.ingestor.getCounters();
      const payload = {
        ok: true,
        uptime_ms: Math.floor(process.uptime() * 1000),
        pi_logger: this.options.piLoggerBase,
        last_ingest_ms: this.lastIngestAt,
        last_error: this.lastError,
        events_in: counters.events_in,
        events_bad_json: counters.events_bad_json,
        events_out: counters.events_out,
        nodes_seen: counters.nodes_seen,
        tools: listTools().length,
      };
      return this.respondJson(res, payload);
    }
    if (url.pathname === "/metrics") {
      const counters = this.ingestor.getCounters();
      const payload = {
        events_in: counters.events_in,
        events_bad_json: counters.events_bad_json,
        frames_out: counters.events_out,
        nodes_seen: counters.nodes_seen,
        tools: listTools().length,
      };
      return this.respondJson(res, payload);
    }
    if (url.pathname === "/tools") {
      return this.respondJson(res, { items: listTools() });
    }
    if (url.pathname === "/api/flash") {
      return this.respondJson(res, this.buildFlashInfo(req));
    }
    if (url.pathname === "/api/tool/run" && req.method === "POST") {
      let body = "";
      req.on("data", (chunk) => body += chunk);
      req.on("end", async () => {
        try {
          const payload = body ? JSON.parse(body) : {};
          const name = payload.name;
          const input = payload.input ?? {};
          if (!name) {
            res.writeHead(400);
            res.end("missing tool name");
            return;
          }
          const result = await this.runToolByName(name, input);
          this.respondJson(res, result);
        } catch (err: any) {
          res.writeHead(400);
          res.end(err?.message ?? "tool error");
        }
      });
      return;
    }
    if (url.pathname === "/api/events/recent") {
      const limit = Number(url.searchParams.get("limit") ?? "50");
      const safeLimit = Number.isFinite(limit) ? Math.max(1, Math.min(200, limit)) : 50;
      const items = this.eventBuffer.slice(-safeLimit).map((ev) => ({
        ...ev,
        data: ev.data ?? {},
      }));
      return this.respondJson(res, { items });
    }
    if (url.pathname === "/flash/esp32") {
      return this.respondFlashHtml(res, "esp32", "ESP32 DevKit", "/flash/manifest.json");
    }
    if (url.pathname === "/flash/esp32c3") {
      return this.respondFlashHtml(res, "esp32c3", "ESP32-C3 DevKit", "/flash/manifest-esp32c3.json");
    }
    if (url.pathname === "/flash/portal-cyd") {
      return this.respondFlashHtml(res, "portal-cyd", "Ops Portal CYD", "/flash-portal/manifest-portal-cyd.json");
    }
    if (url.pathname.startsWith("/flash/")) {
      const rel = url.pathname.replace(/^\/flash\/+/, "");
      return this.serveStaticFrom(res, this.options.flashDir, rel || "index.html");
    }
    if (url.pathname.startsWith("/flash-portal/") && this.options.portalFlashDir) {
      const rel = url.pathname.replace(/^\/flash-portal\/+/, "");
      return this.serveStaticFrom(res, this.options.portalFlashDir, rel || "index.html");
    }
    if (url.pathname === "/opsportal/state") {
      return this.respondJson(res, this.buildOpsPortalState());
    }
    if (url.pathname === "/opsportal/cmd" && req.method === "POST") {
      let body = "";
      req.on("data", (chunk) => body += chunk);
      req.on("end", async () => {
        try {
          const payload = body ? JSON.parse(body) : {};
          const cmd = payload.cmd;
          const args = payload.args ?? {};
          if (!cmd) {
            res.writeHead(400);
            res.end("missing cmd");
            return;
          }
          const result = await this.runToolByName(cmd, args);
          this.respondJson(res, result);
        } catch (err: any) {
          res.writeHead(400);
          res.end(err?.message ?? "cmd error");
        }
      });
      return;
    }
    if (url.pathname === "/tools/run" && req.method === "POST") {
      let body = "";
      req.on("data", (chunk) => body += chunk);
      req.on("end", async () => {
        try {
          const payload = body ? JSON.parse(body) : {};
          const name = payload.name;
          const input = payload.input ?? {};
          if (!name) {
            res.writeHead(400);
            res.end("missing tool name");
            return;
          }
          const result = await this.runToolByName(name, input);
          this.respondJson(res, result);
        } catch (err: any) {
          res.writeHead(400);
          res.end(err?.message ?? "tool error");
        }
      });
      return;
    }
    if (url.pathname === "/nodes") {
      const nodes = this.ingestor.getNodes();
      return this.respondJson(res, { items: nodes });
    }
    if (url.pathname === "/") {
      return this.serveStatic(res, "index.html");
    }
    if (url.pathname.startsWith("/assets/") || url.pathname.startsWith("/spectrum/")) {
      return this.serveStatic(res, url.pathname.slice(1));
    }
    if (url.pathname === "/demo.ndjson") {
      return this.serveDemo(res);
    }
    return this.serveStatic(res, url.pathname.slice(1));
  }

  private respondJson(res: http.ServerResponse, payload: any) {
    const body = JSON.stringify(payload);
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-store",
    });
    res.end(body);
  }

  private serveStatic(res: http.ServerResponse, relPath: string) {
    const safePath = relPath.replace(/^\/+/, "");
    const abs = resolve(join(this.options.publicDir, safePath));
    if (!abs.startsWith(resolve(this.options.publicDir))) {
      res.writeHead(403);
      res.end("Forbidden");
      return;
    }
    if (!existsSync(abs) || statSync(abs).isDirectory()) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    const ext = abs.split(".").pop() ?? "";
    const contentType =
      ext === "html" ? "text/html" :
      ext === "js" ? "application/javascript" :
      ext === "css" ? "text/css" :
      "application/octet-stream";
    res.writeHead(200, { "Content-Type": contentType });
    createReadStream(abs).pipe(res);
  }

  private serveStaticFrom(res: http.ServerResponse, rootDir: string, relPath: string) {
    const safePath = relPath.replace(/^\/+/, "");
    const abs = resolve(join(rootDir, safePath));
    if (!abs.startsWith(resolve(rootDir))) {
      res.writeHead(403);
      res.end("Forbidden");
      return;
    }
    if (!existsSync(abs) || statSync(abs).isDirectory()) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    const ext = abs.split(".").pop() ?? "";
    const contentType =
      ext === "html" ? "text/html" :
      ext === "js" ? "application/javascript" :
      ext === "css" ? "text/css" :
      ext === "json" ? "application/json" :
      "application/octet-stream";
    res.writeHead(200, { "Content-Type": contentType });
    createReadStream(abs).pipe(res);
  }

  private serveDemo(res: http.ServerResponse) {
    const demoPath = join(this.options.publicDir, "demo.ndjson");
    if (!existsSync(demoPath)) {
      res.writeHead(404);
      res.end("No demo file. Generate with `sods stream --frames --out ./cli/sods/public/demo.ndjson`");
      return;
    }
    res.writeHead(200, { "Content-Type": "application/x-ndjson" });
    createReadStream(demoPath).pipe(res);
  }

  private buildOpsPortalState() {
    const counters = this.ingestor.getCounters();
    const nodes = this.ingestor.getNodes();
    const tools = listTools();
    const buttons = tools.slice(0, 6).map((tool) => ({
      id: tool.name,
      label: tool.name.split(".").pop() ?? tool.name,
      kind: "tool",
      enabled: tool.kind === "passive",
      glow_level: 0.2,
      actions: [{ id: tool.name, label: tool.name, cmd: tool.name }],
    }));
    return {
      connection: {
        ok: true,
        last_ok_ms: nowMs(),
        error: this.lastError ?? "",
      },
      mode: {
        name: "sods",
        since_ms: nowMs() - 30_000,
      },
      nodes: {
        total: nodes.length,
        online: nodes.filter((n) => nowMs() - n.last_seen < 60_000).length,
        last_announce_ms: nodes[0]?.last_seen ?? 0,
      },
      ingest: {
        ok_rate: counters.events_out,
        err_rate: counters.events_bad_json,
        last_ok_ms: this.lastIngestAt,
        last_err_ms: 0,
      },
      buttons,
      frames: this.lastFrames,
    };
  }

  private async handleStatus(res: http.ServerResponse) {
    const counters = this.ingestor.getCounters();
    const nodes = this.ingestor.getNodes();
    const station = {
      ok: true,
      uptime_ms: Math.floor(process.uptime() * 1000),
      last_ingest_ms: this.lastIngestAt,
      last_error: this.lastError ?? "",
      pi_logger: this.options.piLoggerBase,
      nodes_total: nodes.length,
      nodes_online: nodes.filter((n) => nowMs() - n.last_seen < 60_000).length,
      tools: listTools().length,
    };

    const logger = await this.fetchLoggerHealth();
    this.respondJson(res, { station, logger });
  }

  private async handlePortalState(req: http.IncomingMessage, res: http.ServerResponse) {
    const counters = this.ingestor.getCounters();
    const nodes = this.ingestor.getNodes();
    const stationVersion = this.readStationVersion();
    const logger = await this.fetchLoggerHealth();
    const lastEventTs = this.lastEvent?.event_ts ?? null;
    const lastEventMs = lastEventTs ? Date.parse(lastEventTs) : 0;

    const now = nowMs();
    const modeStats = this.computeModeStats();

    const topNodes = [...nodes]
      .sort((a, b) => b.last_seen - a.last_seen)
      .slice(0, 5)
      .map((n) => ({
        node_id: n.node_id,
        last_seen: n.last_seen,
        confidence: n.confidence,
        hostname: n.hostname,
        ip: n.ip,
      }));

    const lastSeenByNode: Record<string, number> = {};
    for (const n of nodes) {
      lastSeenByNode[n.node_id] = n.last_seen;
    }

    const aliases: Record<string, string> = { ...this.readAliases() };
    const recent = this.eventBuffer.slice(-300);
    for (const ev of recent) {
      const data = ev.data ?? {};
      const deviceId = String((data as any).device_id ?? (data as any).deviceId ?? (data as any).device ?? (data as any).addr ?? (data as any).address ?? (data as any).mac ?? (data as any).mac_address ?? (data as any).bssid ?? ev.node_id ?? "");
      const ssid = String((data as any).ssid ?? "");
      const hostname = String((data as any).hostname ?? (data as any).host ?? "");
      const ip = String((data as any).ip ?? (data as any).ip_addr ?? (data as any).ip_address ?? "");
      const alias = hostname || ssid || ip || "";
      if (deviceId && alias && !aliases[deviceId]) {
        aliases[deviceId] = alias;
      }
      if (ev.node_id && alias && !aliases[`node:${ev.node_id}`]) {
        aliases[`node:${ev.node_id}`] = alias;
      }
    }

    const payload = {
      station: {
        ok: true,
        version: stationVersion,
        uptime_ms: Math.floor(process.uptime() * 1000),
        last_ingest_ms: this.lastIngestAt,
        last_error: this.lastError ?? "",
        pi_logger: this.options.piLoggerBase,
        nodes_total: nodes.length,
        nodes_online: nodes.filter((n) => now - n.last_seen < 60_000).length,
        tools: listTools().length,
      },
      logger: {
        ok: logger.ok,
        url: this.options.piLoggerBase,
        status: logger.status ?? "",
        last_event_ts: lastEventTs,
        last_event_ms: lastEventMs,
      },
      nodes: {
        active_count: nodes.filter((n) => now - n.last_seen < 60_000).length,
        last_seen_by_node_id: lastSeenByNode,
        top_nodes: topNodes,
      },
      modes: modeStats,
      tools: {
        count: listTools().length,
        items: listTools(),
      },
      aliases,
      flash: this.buildFlashInfo(req),
      frames: this.lastFrames,
    };

    this.respondJson(res, payload);
  }

  private async fetchLoggerHealth() {
    try {
      const res = await fetch(`${this.options.piLoggerBase}/health`, { method: "GET" });
      if (!res.ok) {
        return { ok: false, status: `HTTP ${res.status}` };
      }
      const json = await res.json();
      return { ok: true, status: "ok", detail: json };
    } catch (err: any) {
      return { ok: false, status: err?.message ?? "offline" };
    }
  }

  private readStationVersion() {
    try {
      const pkgPath = new URL("../../package.json", import.meta.url).pathname;
      const raw = JSON.parse(readFileSync(pkgPath, "utf8"));
      return raw.version ?? "unknown";
    } catch {
      return "unknown";
    }
  }

  private computeModeStats() {
    const now = nowMs();
    const getLast = (matcher: (k: string) => boolean) => {
      for (let i = this.eventBuffer.length - 1; i >= 0; i -= 1) {
        const ev = this.eventBuffer[i];
        if (matcher(ev.kind)) {
          const ts = Date.parse(ev.event_ts);
          return Number.isFinite(ts) ? ts : 0;
        }
      }
      return 0;
    };
    const wifiLast = getLast((k) => k.includes("wifi"));
    const bleLast = getLast((k) => k.includes("ble"));
    const rfLast = getLast((k) => k.includes("rf"));
    const gpsLast = getLast((k) => k.includes("gps"));
    const build = (last: number) => ({
      active: last > 0 && now - last < 60_000,
      last_ms: last,
    });
    return {
      net: build(wifiLast),
      ble: build(bleLast),
      rf: build(rfLast),
      gps: build(gpsLast),
    };
  }

  private buildToolRegistry() {
    const registry = loadToolRegistry();
    const presets = loadPresets();
    return {
      ...registry,
      presets: {
        count: presets.presets.length,
        items: presets.presets,
      },
    };
  }

  private buildPresets() {
    return loadPresets();
  }

  private async runToolByName(name: string, input: Record<string, unknown>): Promise<ToolRunResult> {
    const registry = loadToolRegistry();
    const tool = registry.tools.find((t) => t.name === name);
    if (!tool) {
      return {
        ok: false,
        name,
        exit_code: 1,
        duration_ms: 0,
        stdout: "",
        stderr: `unknown tool: ${name}`,
      };
    }
    if (tool.runner === "builtin") {
      const result = await runTool(name, input as Record<string, string | undefined>, this.eventBuffer);
      const urls = result.output ? result.output.match(/https?:\/\/[^\s"'<>]+/g) ?? [] : [];
      const payload: ToolRunResult = {
        ok: result.ok,
        name,
        exit_code: result.ok ? 0 : 1,
        duration_ms: Math.round(result.duration_ms),
        stdout: result.output,
        stderr: "",
        result_json: result.data ?? undefined,
        urls: urls.length ? urls : undefined,
      };
      this.emitToolEvents(name, payload);
      return payload;
    }
    const result = await runScriptTool(tool as ToolEntry, input);
    this.emitToolEvents(name, result);
    return result;
  }

  private emitToolEvents(name: string, result: ToolRunResult) {
    const now = nowMs();
    const base = {
      recv_ts: now,
      event_ts: new Date(now).toISOString(),
      node_id: "station",
      severity: result.ok ? "info" : "warn",
      summary: `tool:${name} ${result.ok ? "ok" : "err"}`,
    };

    const emit = (kind: string, data: Record<string, unknown>) => {
      const ev: CanonicalEvent = { id: `tool-${name}-${now}-${Math.random()}`, kind, data, ...base };
      this.frameEngine.ingest(ev);
      this.eventBuffer.push(ev);
      if (this.eventBuffer.length > 2000) this.eventBuffer.splice(0, this.eventBuffer.length - 2000);
      const payload = JSON.stringify(ev);
      for (const ws of this.eventsClients) {
        ws.send(payload);
      }
      if (this.localLogStream) {
        this.localLogStream.write(payload + "\n");
      }
    };

    emit("tool.run", {
      tool: name,
      ok: result.ok,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
    });

    if (name === "net.wifi_scan") {
      const lines = (result.result_json as any)?.lines ?? result.stdout?.split("\n") ?? [];
      for (const line of lines) {
        const macMatch = String(line).match(/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/);
        if (!macMatch) continue;
        const ssid = String(line).split(macMatch[0])[0].trim();
        const channelMatch = String(line).match(/\bch(?:annel)?\s*:?(\d{1,3})\b/i) ?? String(line).match(/\s(\d{1,3})\s*$/);
        const rssiMatch = String(line).match(/-?\d{2,3}\b/);
        emit("wifi.scan", {
          bssid: macMatch[0],
          ssid: ssid || undefined,
          channel: channelMatch ? Number(channelMatch[1]) : undefined,
          rssi: rssiMatch ? Number(rssiMatch[0]) : undefined,
          line,
          device_id: macMatch[0],
        });
      }
    }

    if (name === "net.arp") {
      const lines = (result.result_json as any)?.lines ?? result.stdout?.split("\n") ?? [];
      for (const line of lines) {
        const macMatch = String(line).match(/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/);
        if (!macMatch) continue;
        const ipMatch = String(line).match(/(\d{1,3}\.){3}\d{1,3}/);
        emit("net.arp", {
          mac: macMatch[0],
          ip: ipMatch ? ipMatch[0] : undefined,
          device_id: macMatch[0],
          line,
        });
      }
    }

    if (name === "camera.viewer") {
      const url = (result.result_json as any)?.url ?? result.urls?.[0] ?? result.stdout;
      if (url) {
        try {
          const u = new URL(url);
          emit("camera.viewer", {
            url,
            host: u.hostname,
            device_id: u.hostname,
          });
        } catch {
          emit("camera.viewer", { url });
        }
      }
    }
  }

  private async handlePresetRun(req: http.IncomingMessage, res: http.ServerResponse) {
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", async () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const id = payload.id;
        if (!id) {
          res.writeHead(400);
          res.end("missing preset id");
          return;
        }
        const presets = loadPresets().presets;
        const preset = presets.find((p) => p.id === id);
        if (!preset) {
          res.writeHead(404);
          res.end("preset not found");
          return;
        }
        const result = await runPreset(preset, (name, input) => this.runToolByName(name, input));
        this.respondJson(res, { ok: result.ok, id, results: result.results });
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "preset error");
      }
    });
  }

  private async handleScratchRun(req: http.IncomingMessage, res: http.ServerResponse) {
    if (!this.isLocalRequest(req)) {
      res.writeHead(403);
      res.end("scratch runs allowed only on localhost station");
      return;
    }
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", async () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const runner = payload.runner;
        const script = payload.script;
        const input = payload.input ?? {};
        if (!runner || !script) {
          res.writeHead(400);
          res.end("runner and script required");
          return;
        }
        const result = await runScratch(runner, script, input);
        this.respondJson(res, result);
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "scratch error");
      }
    });
  }

  private handleUserAliasEdit(req: http.IncomingMessage, res: http.ServerResponse, path: string) {
    if (!this.isLocalRequest(req)) {
      res.writeHead(403);
      res.end("alias edits allowed only on localhost station");
      return;
    }
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const id = payload.id as string | undefined;
        const alias = payload.alias as string | undefined;
        if (!id) {
          res.writeHead(400);
          res.end("missing id");
          return;
        }
        const action = path.split("/").pop() ?? "";
        const userPath = this.aliasRegistryPath();
        const current = this.readAliases(userPath);
        if (action === "delete") {
          delete current[id];
        } else {
          if (!alias) {
            res.writeHead(400);
            res.end("missing alias");
            return;
          }
          current[id] = alias;
        }
        this.writeAliases(userPath, current);
        res.end("ok");
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "alias error");
      }
    });
  }

  private aliasRegistryPath() {
    const repoRoot = resolve(new URL("../../..", import.meta.url).pathname);
    return join(repoRoot, "docs", "aliases.user.json");
  }

  private readAliases(userPath?: string): Record<string, string> {
    const repoRoot = resolve(new URL("../../..", import.meta.url).pathname);
    const official = join(repoRoot, "docs", "aliases.json");
    const user = userPath ?? this.aliasRegistryPath();
    const out: Record<string, string> = {};
    const load = (path: string) => {
      if (!existsSync(path)) return;
      try {
        const raw = JSON.parse(readFileSync(path, "utf8"));
        const aliases = raw.aliases ?? raw;
        if (aliases && typeof aliases === "object") {
          for (const [key, value] of Object.entries(aliases)) {
            if (typeof value === "string" && value.length) out[key] = value;
          }
        }
      } catch {
        // ignore invalid alias files
      }
    };
    load(official);
    load(user);
    return out;
  }

  private writeAliases(path: string, aliases: Record<string, string>) {
    const payload = { aliases };
    writeFileSync(path, JSON.stringify(payload, null, 2));
  }

  private handleUserToolEdit(req: http.IncomingMessage, res: http.ServerResponse, path: string) {
    if (!this.isLocalRequest(req)) {
      res.writeHead(403);
      res.end("user tool edits allowed only on localhost station");
      return;
    }
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const entry = payload.entry as ToolEntry;
        const script = payload.script as string | undefined;
        const action = path.split("/").pop() ?? "";
        if (!entry?.name) {
          res.writeHead(400);
          res.end("missing tool entry");
          return;
        }
        const { userPath, userToolsDir, repoRoot } = toolRegistryPaths();
        mkdirSync(userToolsDir, { recursive: true });
        const ext = entry.runner === "python" ? "py" : entry.runner === "node" ? "mjs" : "sh";
        const safeName = entry.name.replace(/[^a-zA-Z0-9._-]/g, "_");
        const scriptRel = `tools/user/${safeName}.${ext}`;
        const scriptAbs = resolve(join(repoRoot, scriptRel));

        if (action === "delete") {
          const registry = this.readUserRegistry(userPath);
          const next = registry.tools.filter((t: ToolEntry) => t.name !== entry.name);
          this.writeUserRegistry(userPath, next);
          res.end("ok");
          return;
        }

        if (!script && action === "add") {
          res.writeHead(400);
          res.end("script required for add");
          return;
        }
        if (script) {
          writeFileSync(scriptAbs, script, "utf8");
          if (entry.runner === "shell") chmodSync(scriptAbs, 0o755);
        }
        entry.entry = scriptRel;
        const registry = this.readUserRegistry(userPath);
        const next = registry.tools.filter((t: ToolEntry) => t.name !== entry.name);
        next.push(entry);
        this.writeUserRegistry(userPath, next);
        res.end("ok");
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "user tool error");
      }
    });
  }

  private handleUserPresetEdit(req: http.IncomingMessage, res: http.ServerResponse, path: string) {
    if (!this.isLocalRequest(req)) {
      res.writeHead(403);
      res.end("user preset edits allowed only on localhost station");
      return;
    }
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const preset = payload.preset;
        const action = path.split("/").pop() ?? "";
        if (!preset?.id) {
          res.writeHead(400);
          res.end("missing preset");
          return;
        }
        const { userPath } = presetRegistryPaths();
        const registry = this.readUserPresets(userPath);
        if (action === "delete") {
          const next = registry.presets.filter((p: any) => p.id !== preset.id);
          this.writeUserPresets(userPath, next);
          res.end("ok");
          return;
        }
        const next = registry.presets.filter((p: any) => p.id !== preset.id);
        next.push(preset);
        this.writeUserPresets(userPath, next);
        res.end("ok");
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "user preset error");
      }
    });
  }

  private readUserRegistry(path: string) {
    if (!existsSync(path)) return { tools: [] as ToolEntry[] };
    try {
      return JSON.parse(readFileSync(path, "utf8"));
    } catch {
      return { tools: [] as ToolEntry[] };
    }
  }

  private writeUserRegistry(path: string, tools: ToolEntry[]) {
    writeFileSync(path, JSON.stringify({ version: "1.0", tools }, null, 2));
  }

  private readUserPresets(path: string) {
    if (!existsSync(path)) return { presets: [] as any[] };
    try {
      return JSON.parse(readFileSync(path, "utf8"));
    } catch {
      return { presets: [] as any[] };
    }
  }

  private writeUserPresets(path: string, presets: any[]) {
    writeFileSync(path, JSON.stringify({ version: "1.0", presets }, null, 2));
  }

  private isLocalRequest(req: http.IncomingMessage) {
    const addr = req.socket.remoteAddress ?? "";
    return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
  }

  private buildFlashInfo(req: http.IncomingMessage) {
    const host = req.headers.host ?? "localhost:9123";
    const base = `http://${host}`;
    return {
      base_url: base,
      items: [
        {
          id: "esp32",
          label: "ESP32 DevKit",
          url: `${base}/flash/esp32`,
          manifest: `${base}/flash/manifest.json`,
        },
        {
          id: "esp32c3",
          label: "ESP32-C3 DevKit",
          url: `${base}/flash/esp32c3`,
          manifest: `${base}/flash/manifest-esp32c3.json`,
        },
        {
          id: "portal-cyd",
          label: "Ops Portal CYD",
          url: `${base}/flash/portal-cyd`,
          manifest: `${base}/flash-portal/manifest-portal-cyd.json`,
        },
      ],
    };
  }

  private respondFlashHtml(res: http.ServerResponse, chip: string, label: string, manifestPath: string) {
    const html = `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Flash ${label}</title>
    <style>
      body { background:#0a0a0c; color:#f5f5f5; font-family: -apple-system, Helvetica, Arial; padding:32px; }
      .card { max-width:720px; margin:0 auto; background:#121216; border:1px solid #2a2a2f; border-radius:16px; padding:20px; box-shadow:0 0 24px rgba(255,60,60,0.18); }
      h1 { margin:0 0 8px 0; font-size:22px; }
      p { color:#b9b9c0; line-height:1.4; }
      a { color:#ff3c3c; }
      .button { margin-top:16px; display:inline-block; padding:10px 18px; border-radius:20px; background:#ff3c3c; color:#fff; text-decoration:none; box-shadow:0 0 14px rgba(255,60,60,0.4); }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Flash ${label}</h1>
      <p>Use the SODS web flasher to install firmware for ${label}. This page points to the repo-local ESP Web Tools manifest.</p>
      <p>Manifest: <a href="${manifestPath}">${manifestPath}</a></p>
      <a class="button" href="/flash/index.html?chip=${chip}">Open Web Flasher</a>
    </div>
  </body>
</html>`;
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(html);
  }
}
