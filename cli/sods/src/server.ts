import http from "node:http";
import os from "node:os";
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
import { loadRunbooks } from "./runbooks.js";
import { runScriptTool, runScratch, RunResult as ToolRunResult } from "./tool-runner.js";
import { runPreset } from "./preset-runner.js";
import { runRunbook } from "./runbook-runner.js";
import { toolRegistryPaths } from "./tool-registry.js";

type ServerOptions = {
  port: number;
  piLoggerBase: string;
  publicDir: string;
  flashDir: string;
  portalFlashDir?: string;
  p4FlashDir?: string;
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
  private nodePresence = new Map<string, { state: string; lastError?: string; updatedAt: number }>();
  private activeTool: { name: string; started_at: number; status: string; ok?: boolean } | null = null;
  private activeRunbook: { id: string; started_at: number; status: string; step?: string; ok?: boolean } | null = null;
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
    if (url.pathname === "/api/nodes") {
      return this.respondJson(res, this.buildNodePresence());
    }
    if (url.pathname === "/api/registry/nodes") {
      return this.handleRegistryNodes(res);
    }
    if (url.pathname === "/api/registry/nodes/forget" && req.method === "POST") {
      return this.handleRegistryForget(req, res);
    }
    if (url.pathname === "/api/registry/nodes/factory-reset" && req.method === "POST") {
      return this.handleRegistryFactoryReset(req, res);
    }
    if (url.pathname === "/api/node/connect" && req.method === "POST") {
      return this.handleNodeConnect(req, res);
    }
    if (url.pathname === "/api/node/identify" && req.method === "POST") {
      return this.handleNodeIdentify(req, res);
    }
    if (url.pathname === "/api/runbooks") {
      return this.respondJson(res, this.buildRunbooks());
    }
    if (url.pathname === "/api/runbook/run" && req.method === "POST") {
      return this.handleRunbookRun(req, res);
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
        pi_logger: this.ingestor.getActiveBaseURL(),
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
    if (url.pathname === "/api/flash/diagnostics") {
      return this.respondJson(res, this.buildFlashDiagnostics(req));
    }
    if (url.pathname === "/api/p4/status") {
      const ip = url.searchParams.get("ip");
      if (!ip) {
        res.writeHead(400);
        res.end("missing ip");
        return;
      }
      fetch(`http://${ip}/status`, { method: "GET" })
        .then(async (r) => {
          res.writeHead(r.status, { "Content-Type": "application/json" });
          res.end(await r.text());
        })
        .catch((err) => {
          res.writeHead(502);
          res.end(String(err?.message ?? "p4 fetch failed"));
        });
      return;
    }
    if (url.pathname === "/api/p4/god") {
      const ip = url.searchParams.get("ip");
      if (!ip) {
        res.writeHead(400);
        res.end("missing ip");
        return;
      }
      fetch(`http://${ip}/god`, { method: "POST" })
        .then(async (r) => {
          res.writeHead(r.status, { "Content-Type": "application/json" });
          res.end(await r.text());
        })
        .catch((err) => {
          res.writeHead(502);
          res.end(String(err?.message ?? "p4 fetch failed"));
        });
      return;
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
    if (url.pathname === "/flash") {
      return this.serveStaticFrom(res, this.options.flashDir, "index.html");
    }
    if (url.pathname === "/flash/esp32") {
      return this.respondFlashHtml(res, "esp32", "ESP32 DevKit", "/flash/manifest.json");
    }
    if (url.pathname === "/flash/esp32c3") {
      return this.respondFlashHtml(res, "esp32c3", "ESP32-C3 (XIAO/DevKit)", "/flash/manifest-esp32c3.json");
    }
    if (url.pathname === "/flash/portal-cyd") {
      return this.respondFlashHtml(res, "portal-cyd", "Ops Portal CYD", "/flash-portal/manifest-portal-cyd.json");
    }
    if (url.pathname === "/flash/p4") {
      return this.respondFlashHtml(res, "esp32p4", "ESP32-P4 God Button", "/flash-p4/manifest-p4.json");
    }
    if (url.pathname.startsWith("/flash/")) {
      const rel = url.pathname.replace(/^\/flash\/+/, "");
      return this.serveStaticFrom(res, this.options.flashDir, rel || "index.html");
    }
    if (url.pathname.startsWith("/flash-portal/") && this.options.portalFlashDir) {
      const rel = url.pathname.replace(/^\/flash-portal\/+/, "");
      return this.serveStaticFrom(res, this.options.portalFlashDir, rel || "index.html");
    }
    if (url.pathname.startsWith("/flash-p4/") && this.options.p4FlashDir) {
      const rel = url.pathname.replace(/^\/flash-p4\/+/, "");
      return this.serveStaticFrom(res, this.options.p4FlashDir, rel || "index.html");
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

  private buildOpsPortalState() {
    const counters = this.ingestor.getCounters();
    const nodes = this.ingestor.getNodes();
    const tools = listTools();
    const buttons = tools.slice(0, 6).map((tool) => ({
      id: tool.name,
      label: tool.title ?? (tool.name.split(".").pop() ?? tool.name),
      kind: "tool",
      enabled: tool.kind === "passive",
      glow_level: 0.2,
      actions: [{ id: tool.name, label: tool.title ?? tool.name, cmd: tool.name }],
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
      pi_logger: this.ingestor.getActiveBaseURL(),
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
    const framesSummary = this.buildFramesSummary();
    const actionState = {
      tool: this.activeTool,
      runbook: this.activeRunbook,
    };

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
        pi_logger: this.ingestor.getActiveBaseURL(),
        nodes_total: nodes.length,
        nodes_online: nodes.filter((n) => now - n.last_seen < 60_000).length,
        tools: listTools().length,
      },
      logger: {
        ok: logger.ok,
        url: this.ingestor.getActiveBaseURL(),
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
      presets: {
        count: loadPresets().presets.length,
        items: loadPresets().presets,
      },
      runbooks: {
        count: loadRunbooks().runbooks.length,
        items: loadRunbooks().runbooks,
      },
      aliases,
      flash: this.buildFlashInfo(req),
      actions: actionState,
      quick_stats: this.buildQuickStats(framesSummary),
      frames_summary: framesSummary,
      frames: this.lastFrames,
    };

    this.respondJson(res, payload);
  }

  private buildFramesSummary() {
    const bySource: Record<string, number> = {};
    const byNode: Record<string, number> = {};
    const byChannel: Record<string, number> = {};
    for (const frame of this.lastFrames) {
      const src = frame.source ?? "unknown";
      bySource[src] = (bySource[src] ?? 0) + 1;
      const node = frame.node_id ?? "unknown";
      byNode[node] = (byNode[node] ?? 0) + 1;
      const ch = Number.isFinite(frame.channel) ? String(frame.channel) : "unknown";
      byChannel[ch] = (byChannel[ch] ?? 0) + 1;
    }
    const bins = Object.entries(byChannel)
      .map(([channel, count]) => ({ channel, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 8);
    return { total: this.lastFrames.length, by_source: bySource, by_node: byNode, bins };
  }

  private buildQuickStats(summary: { total: number }) {
    const now = nowMs();
    const lastEventTs = this.lastEvent?.event_ts ? Date.parse(this.lastEvent.event_ts) : 0;
    const lastAge = lastEventTs > 0 ? Math.max(0, Math.round((now - lastEventTs) / 1000)) : 0;
    return [
      `frames:${summary.total}`,
      `nodes:${this.ingestor.getNodes().filter((n) => now - n.last_seen < 60_000).length}`,
      lastAge > 0 ? `last:${lastAge}s` : "last:na",
    ];
  }

  private buildNodePresence() {
    const nodes = this.ingestor.getNodes();
    const now = nowMs();
    const recentEvents = this.eventBuffer.slice(-400);
    const byNodeKind = new Map<string, Set<string>>();
    for (const ev of recentEvents) {
      if (!byNodeKind.has(ev.node_id)) byNodeKind.set(ev.node_id, new Set());
      byNodeKind.get(ev.node_id)!.add(ev.kind);
    }

    const visibleNodes = nodes.filter((node) => {
      const age = now - node.last_seen;
      const ip = String(node.ip ?? "").trim();
      const hostname = String(node.hostname ?? "").trim();
      return Boolean(ip || hostname) || age < 30_000;
    });

    return {
      items: visibleNodes.map((node) => {
        const override = this.nodePresence.get(node.node_id);
        const age = now - node.last_seen;
        let state = "offline";
        if (override && override.state === "connecting" && now - override.updatedAt < 30_000) {
          state = "connecting";
        } else if (age < 30_000) {
          state = "online";
        } else if (override && override.state === "error" && now - override.updatedAt < 60_000) {
          state = "error";
        }
        const kinds = byNodeKind.get(node.node_id) ?? new Set();
        const canScanWifi = Array.from(kinds).some((k) => k.includes("wifi"));
        const canScanBle = Array.from(kinds).some((k) => k.includes("ble"));
        const canFrames = this.lastFrames.some((f) => f.node_id === node.node_id);
        const ip = String(node.ip ?? "").trim();
        const hostname = String(node.hostname ?? "").trim();
        const canWhoami = Boolean(ip || hostname);
        const canFlash = node.node_id !== "station";
        return {
          node_id: node.node_id,
          state,
          last_seen: node.last_seen,
          last_seen_age_ms: age,
          last_error: override?.lastError ?? "",
          ip: ip || undefined,
          mac: node.mac,
          hostname: hostname || undefined,
          confidence: node.confidence,
          capabilities: {
            canScanWifi,
            canScanBle,
            canFrames,
            canFlash,
            canWhoami,
          },
          provenance_id: node.node_id,
        };
      }),
    };
  }

  private async handleNodeConnect(req: http.IncomingMessage, res: http.ServerResponse) {
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", async () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const nodeId = payload.node_id;
        if (!nodeId) {
          res.writeHead(400);
          res.end("missing node_id");
          return;
        }
        this.nodePresence.set(nodeId, { state: "connecting", updatedAt: nowMs() });
        const hostHint = String(payload.host ?? payload.hostname ?? "").trim();
        const result = await this.probeNode(nodeId, hostHint);
        this.respondJson(res, result);
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "connect error");
      }
    });
  }

  private async handleNodeIdentify(req: http.IncomingMessage, res: http.ServerResponse) {
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", async () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const nodeId = payload.node_id;
        if (!nodeId) {
          res.writeHead(400);
          res.end("missing node_id");
          return;
        }
        const hostHint = String(payload.host ?? payload.hostname ?? "").trim();
        const result = await this.probeNode(nodeId, hostHint);
        this.respondJson(res, result);
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "identify error");
      }
    });
  }

  private async probeNode(nodeId: string, hostHint = "") {
    const nodes = this.ingestor.getNodes();
    const snapshot = nodes.find((n) => n.node_id === nodeId);
    const normalizedHint = hostHint.trim();
    const inferredHost = /^[0-9a-z.-]+$/i.test(nodeId) ? nodeId : "";
    const host = snapshot?.ip || snapshot?.hostname || normalizedHint || inferredHost;
    if (!host) {
      const errMsg = "node has no ip/hostname";
      this.nodePresence.set(nodeId, { state: "error", lastError: errMsg, updatedAt: nowMs() });
      return { ok: false, node_id: nodeId, error: errMsg };
    }
    const isIPv4 = /^\d{1,3}(\.\d{1,3}){3}$/.test(host);
    const lowerHost = host.toLowerCase();
    const localHints = new Set([
      "localhost",
      "127.0.0.1",
      "::1",
      "mac-local",
      os.hostname().toLowerCase(),
    ]);
    const shouldTryLocalStation = !isIPv4 && (localHints.has(lowerHost) || !lowerHost.includes("."));
    const candidates = [
      `http://${host}/whoami`,
      `http://${host}/health`,
      `http://${host}/api/status`,
      `http://${host}/`,
      ...(shouldTryLocalStation ? [
        `http://127.0.0.1:${this.options.port}/health`,
        `http://localhost:${this.options.port}/health`,
        `http://127.0.0.1:${this.options.port}/api/status`,
      ] : []),
    ];

    let lastErr = "probe failed";
    for (const url of candidates) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 2000);
      try {
        const res = await fetch(url, { method: "GET", signal: controller.signal });
        clearTimeout(timer);
        const text = await res.text();
        if (!res.ok) {
          // Captive portals commonly redirect or return non-JSON pages.
          // Treat reachable HTTP responses as online for claim/connect flow.
          if (res.status >= 300 && res.status < 500 && url.endsWith("/")) {
            this.nodePresence.set(nodeId, { state: "online", updatedAt: nowMs() });
            return {
              ok: true,
              node_id: nodeId,
              host,
              probe_url: url,
              whoami: `portal-http-${res.status}`,
            };
          }
          lastErr = `HTTP ${res.status} @ ${url}`;
          continue;
        }
        this.nodePresence.set(nodeId, { state: "online", updatedAt: nowMs() });
        return { ok: true, node_id: nodeId, whoami: text, host, probe_url: url };
      } catch (err: any) {
        clearTimeout(timer);
        lastErr = err?.message ?? "probe failed";
      }
    }
    this.nodePresence.set(nodeId, { state: "error", lastError: lastErr, updatedAt: nowMs() });
    return { ok: false, node_id: nodeId, error: lastErr };
  }

  private async fetchLoggerHealth() {
    const bases = this.ingestor.getBaseURLs();
    const ordered = [this.ingestor.getActiveBaseURL(), ...bases.filter((b) => b !== this.ingestor.getActiveBaseURL())];
    let lastStatus = "offline";
    const timeoutMs = 1200;

    for (const base of ordered) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const res = await fetch(`${base}/health`, { method: "GET", signal: controller.signal });
        if (!res.ok) {
          lastStatus = `${base} HTTP ${res.status}`;
          continue;
        }
        const json = await res.json();
        clearTimeout(timer);
        return { ok: true, status: "ok", detail: json, url: base };
      } catch (err: any) {
        clearTimeout(timer);
        lastStatus = `${base} ${err?.message ?? "offline"}`;
      } finally {
        clearTimeout(timer);
      }
    }
    return { ok: false, status: lastStatus };
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
    const runbooks = loadRunbooks();
    const runbookTools = runbooks.runbooks.map((rb) => ({
      name: `runbook.${rb.id}`,
      title: rb.title ?? rb.id,
      description: rb.description ?? "",
      runner: "builtin",
      kind: "runbook",
      tags: ["runbook"],
      scope: "runbook",
      output: { format: "json" },
      input_schema: rb.input_schema ?? undefined,
      runbook_id: rb.id,
    }));
    return {
      ...registry,
      tools: [...registry.tools, ...runbookTools],
      presets: {
        count: presets.presets.length,
        items: presets.presets,
      },
      runbooks: {
        count: runbooks.runbooks.length,
        items: runbooks.runbooks,
      },
    };
  }

  private buildPresets() {
    return loadPresets();
  }

  private buildRunbooks() {
    return loadRunbooks();
  }

  private async runToolByName(
    name: string,
    input: Record<string, unknown>,
    context?: { runbookId?: string; stepId?: string }
  ): Promise<ToolRunResult> {
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
    if (!context?.runbookId) {
      this.activeTool = { name, started_at: nowMs(), status: "running" };
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
      if (!context?.runbookId) {
        this.activeTool = { name, started_at: this.activeTool?.started_at ?? nowMs(), status: "done", ok: payload.ok };
      }
      return payload;
    }
    const result = await runScriptTool(tool as ToolEntry, input);
    this.emitToolEvents(name, result);
    if (!context?.runbookId) {
      this.activeTool = { name, started_at: this.activeTool?.started_at ?? nowMs(), status: "done", ok: result.ok };
    }
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
      const stdout = result.stdout ?? "";
      // Honesty rule: system_profiler output is not a scan. Do not synthesize wifi.scan from it.
      if (/^Wi-Fi:\s*$/m.test(stdout) || /CoreWLAN:\s*\d+/i.test(stdout) || /Other Local Wi-Fi Networks:/i.test(stdout)) {
        emit("wifi.scan.unavailable", {
          ok: false,
          reason: "no_scan_tool",
          detail: "tools/wifi-scan.sh could not access a real scan backend (airport/wdutil).",
        });
        return;
      }

      const lines = (result.result_json as any)?.lines ?? stdout.split("\n");
      for (const rawLine of lines) {
        const line = String(rawLine);
        // Expected "airport -s" rows (SSID may contain spaces; BSSID is MAC; then RSSI then channel).
        const m = line.match(/^(.*?)([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\s+(-?\d{2,3})\s+(\d{1,3})\b/);
        if (!m) continue;
        const ssid = m[1].trim();
        const bssid = m[2];
        const rssi = Number(m[3]);
        const channel = Number(m[4]);
        if (!Number.isFinite(rssi) || rssi > 0 || rssi < -120) continue;
        if (!Number.isFinite(channel) || channel <= 0 || channel > 233) continue;

        emit("wifi.scan", {
          bssid,
          ssid: ssid || undefined,
          channel,
          rssi,
          line,
          device_id: bssid,
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

  private async handleRunbookRun(req: http.IncomingMessage, res: http.ServerResponse) {
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", async () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const id = payload.name || payload.id;
        const input = payload.input ?? {};
        if (!id) {
          res.writeHead(400);
          res.end("missing runbook name");
          return;
        }
        const registry = loadRunbooks();
        const runbook = registry.runbooks.find((r) => r.id === id);
        if (!runbook) {
          res.writeHead(404);
          res.end("runbook not found");
          return;
        }
        const startedAt = nowMs();
        this.activeTool = null;
        this.activeRunbook = { id, started_at: startedAt, status: "running" };
        const result = await runRunbook(
          runbook,
          (name, inputArgs) => this.runToolByName(name, inputArgs, { runbookId: id }),
          input,
          (stepId, tool) => {
            this.activeRunbook = { id, started_at: startedAt, status: "running", step: `${stepId}:${tool}` };
          },
          (stepId, tool, stepResult) => {
            if (!stepResult.ok) {
              this.activeRunbook = { id, started_at: startedAt, status: "error", step: `${stepId}:${tool}`, ok: false };
            }
          }
        );
        const endedAt = nowMs();
        this.activeRunbook = { id, started_at: startedAt, status: "done", ok: result.ok };

        const report = this.writeRunbookReport(id, input, startedAt, endedAt, result);
        this.respondJson(res, {
          ok: result.ok,
          id,
          results: result.results,
          summary: `runbook ${id} ${result.ok ? "ok" : "err"}`,
          artifacts: report ? [report] : [],
        });
      } catch (err: any) {
        this.activeRunbook = null;
        res.writeHead(400);
        res.end(err?.message ?? "runbook error");
      }
    });
  }

  private writeRunbookReport(
    id: string,
    input: Record<string, unknown>,
    startedAt: number,
    endedAt: number,
    result: { ok: boolean; results: Record<string, ToolRunResult> }
  ) {
    try {
      const { repoRoot } = toolRegistryPaths();
      const outDir = join(repoRoot, "data", "reports", "runbooks");
      mkdirSync(outDir, { recursive: true });
      const iso = new Date().toISOString().replace(/[:.]/g, "-");
      const filename = `Runbook-${id}-${iso}.json`;
      const path = join(outDir, filename);
      const payload = {
        id,
        ok: result.ok,
        started_at: startedAt,
        ended_at: endedAt,
        input,
        results: result.results,
      };
      writeFileSync(path, JSON.stringify(payload, null, 2));
      return { path, filename };
    } catch {
      return null;
    }
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
    mkdirSync(resolve(path, ".."), { recursive: true });
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
    mkdirSync(resolve(path, ".."), { recursive: true });
    writeFileSync(path, JSON.stringify({ version: "1.0", presets }, null, 2));
  }

  private isLocalRequest(req: http.IncomingMessage) {
    const addr = req.socket.remoteAddress ?? "";
    return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
  }

  private registryNodesPath() {
    const repoRoot = resolve(new URL("../../..", import.meta.url).pathname);
    return join(repoRoot, "workspace", "registry", "nodes.json");
  }

  private readRegistryNodes(): { version: string; nodes: any[] } {
    const path = this.registryNodesPath();
    if (!existsSync(path)) return { version: "1.0", nodes: [] };
    try {
      const raw = JSON.parse(readFileSync(path, "utf8"));
      const nodes = Array.isArray(raw?.nodes) ? raw.nodes : [];
      const version = typeof raw?.version === "string" ? raw.version : "1.0";
      return { version, nodes };
    } catch {
      return { version: "1.0", nodes: [] };
    }
  }

  private writeRegistryNodes(payload: { version: string; nodes: any[] }) {
    const path = this.registryNodesPath();
    mkdirSync(resolve(path, ".."), { recursive: true });
    writeFileSync(path, JSON.stringify(payload, null, 2));
  }

  private handleRegistryNodes(res: http.ServerResponse) {
    return this.respondJson(res, { ok: true, ...this.readRegistryNodes() });
  }

  private handleRegistryForget(req: http.IncomingMessage, res: http.ServerResponse) {
    if (!this.isLocalRequest(req)) {
      res.writeHead(403);
      res.end("node registry edits allowed only on localhost station");
      return;
    }
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const nodeID = String(payload.node_id ?? "").trim();
        if (!nodeID) {
          res.writeHead(400);
          res.end("missing node_id");
          return;
        }
        const current = this.readRegistryNodes();
        const nextNodes = current.nodes.filter((n: any) => String(n?.id ?? "").trim() !== nodeID);
        this.writeRegistryNodes({ version: current.version ?? "1.0", nodes: nextNodes });
        return this.respondJson(res, { ok: true, version: current.version ?? "1.0", nodes: nextNodes });
      } catch (err: any) {
        res.writeHead(400);
        res.end(err?.message ?? "registry forget error");
      }
    });
  }

  private vaultIngestURL() {
    const explicit = (process.env.VAULT_INGEST_URL ?? "").trim();
    if (explicit) return explicit;
    const loggerHost = (process.env.LOGGER_HOST ?? "192.168.8.160").trim() || "192.168.8.160";
    return `http://${loggerHost}:8088/v1/ingest`;
  }

  private async vaultIngest(event: any) {
    const url = this.vaultIngestURL();
    const r = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(event),
    });
    if (!r.ok) {
      const t = await r.text().catch(() => "");
      throw new Error(`vault ingest failed: ${r.status} ${t}`);
    }
  }

  private async handleRegistryFactoryReset(req: http.IncomingMessage, res: http.ServerResponse) {
    if (!this.isLocalRequest(req)) {
      res.writeHead(403);
      res.end("factory reset allowed only on localhost station");
      return;
    }
    let body = "";
    req.on("data", (chunk) => body += chunk);
    req.on("end", async () => {
      const started = Date.now();
      try {
        const payload = body ? JSON.parse(body) : {};
        const nodeID = String(payload.node_id ?? "").trim();
        const host = String(payload.host ?? "").trim();
        if (!nodeID) {
          res.writeHead(400);
          res.end("missing node_id");
          return;
        }
        if (!host) {
          res.writeHead(400);
          res.end("missing host");
          return;
        }
        if (host.includes("localhost") || host.startsWith("127.") || host.startsWith("::1")) {
          res.writeHead(400);
          res.end("refusing localhost host");
          return;
        }

        const requestId = `factory-reset-${Date.now()}-${Math.random().toString(16).slice(2)}`;
        await this.vaultIngest({
          type: "node.maintenance.intent",
          src: "station",
          ts_ms: Date.now(),
          data: { request_id: requestId, op: "factory_reset_networking", node_id: nodeID, host },
        });

        const targetBase = host.startsWith("http://") || host.startsWith("https://") ? host : `http://${host}`;
        const targetURL = `${targetBase.replace(/\/+$/, "")}/api/factory-reset`;
        const rsp = await fetch(targetURL, { method: "POST" });
        const text = await rsp.text().catch(() => "");

        await this.vaultIngest({
          type: "node.maintenance.result",
          src: "station",
          ts_ms: Date.now(),
          data: {
            request_id: requestId,
            op: "factory_reset_networking",
            node_id: nodeID,
            host,
            ok: rsp.ok,
            status: rsp.status,
            body: text.slice(0, 2048),
            duration_ms: Date.now() - started,
          },
        });

        if (!rsp.ok) {
          res.writeHead(502);
          res.end(`device refused: HTTP ${rsp.status} ${text}`);
          return;
        }
        return this.respondJson(res, { ok: true });
      } catch (err: any) {
        res.writeHead(503);
        res.end(err?.message ?? "factory reset failed");
      }
    });
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
          label: "ESP32-C3 (XIAO/DevKit)",
          url: `${base}/flash/esp32c3`,
          manifest: `${base}/flash/manifest-esp32c3.json`,
        },
        {
          id: "portal-cyd",
          label: "Ops Portal CYD",
          url: `${base}/flash/portal-cyd`,
          manifest: `${base}/flash-portal/manifest-portal-cyd.json`,
        },
        {
          id: "esp32p4",
          label: "ESP32-P4 God Button",
          url: `${base}/flash/p4`,
          manifest: `${base}/flash-p4/manifest-p4.json`,
        },
      ],
    };
  }

  private buildFlashDiagnostics(req: http.IncomingMessage) {
    const host = req.headers.host ?? `localhost:${this.options.port}`;
    const base = `http://${host}`;
    const targets = [
      {
        id: "esp32",
        label: "ESP32 DevKit",
        chip: "esp32",
        page: `${base}/flash/esp32`,
        manifestUrl: `${base}/flash/manifest.json`,
        manifestRel: "manifest.json",
        rootDir: this.options.flashDir,
      },
      {
        id: "esp32c3",
        label: "ESP32-C3 (XIAO/DevKit)",
        chip: "esp32c3",
        page: `${base}/flash/esp32c3`,
        manifestUrl: `${base}/flash/manifest-esp32c3.json`,
        manifestRel: "manifest-esp32c3.json",
        rootDir: this.options.flashDir,
      },
      {
        id: "portal-cyd",
        label: "Ops Portal CYD",
        chip: "portal-cyd",
        page: `${base}/flash/portal-cyd`,
        manifestUrl: `${base}/flash-portal/manifest-portal-cyd.json`,
        manifestRel: "manifest-portal-cyd.json",
        rootDir: this.options.portalFlashDir,
      },
      {
        id: "esp32p4",
        label: "ESP32-P4 God Button",
        chip: "esp32p4",
        page: `${base}/flash/p4`,
        manifestUrl: `${base}/flash-p4/manifest-p4.json`,
        manifestRel: "manifest-p4.json",
        rootDir: this.options.p4FlashDir,
      },
    ];

    const items = targets.map((target) => {
      const issues: string[] = [];
      const rootDir = target.rootDir ? resolve(target.rootDir) : "";
      const manifestFile = rootDir ? resolve(join(rootDir, target.manifestRel)) : "";
      let manifestExists = false;
      let manifestOk = false;
      let manifestError = "";
      type FlashPart = { path: string; offset: number; file_exists: boolean; abs_path: string };
      type FlashBuildInfo = { name: string | null; ready: boolean; issues: string[]; parts: FlashPart[] };
      let parts: FlashPart[] = [];
      let buildInfos: FlashBuildInfo[] = [];
      let buildVersion = "";

      if (!rootDir) {
        issues.push("flash root directory is not configured");
      } else if (!existsSync(rootDir)) {
        issues.push("flash root directory is missing");
      }

      if (manifestFile && existsSync(manifestFile)) {
        manifestExists = true;
        try {
          const parsed = JSON.parse(readFileSync(manifestFile, "utf8"));
          const builds = Array.isArray(parsed?.builds) ? parsed.builds : [];
          buildVersion = String(parsed?.version || "");
          if (builds.length === 0) {
            issues.push("manifest has no builds");
          } else {
            buildInfos = builds.map((build: any): FlashBuildInfo => {
              const buildIssues: string[] = [];
              const name = String(build?.name || build?.label || "");
              const rawParts = Array.isArray(build?.parts) ? build.parts : [];
              if (rawParts.length === 0) {
                buildIssues.push("build has no parts");
              }
              const buildParts: FlashPart[] = rawParts.map((part: any): FlashPart => {
                const rel = String(part?.path || "");
                const abs = rootDir ? resolve(join(rootDir, rel)) : "";
                const exists = !!abs && existsSync(abs);
                if (!exists) {
                  buildIssues.push(`missing artifact: ${rel}`);
                }
                return {
                  path: rel,
                  offset: Number(part?.offset || 0),
                  file_exists: exists,
                  abs_path: abs,
                };
              });
              return {
                name: name || null,
                ready: buildIssues.length === 0 && buildParts.length > 0 && buildParts.every((p: FlashPart) => p.file_exists),
                issues: buildIssues,
                parts: buildParts,
              };
            });

            const anyReady = buildInfos.some((b: FlashBuildInfo) => b.ready);
            // Backward compatibility: keep top-level `parts` as the first build's parts.
            parts = buildInfos[0]?.parts || [];

            if (!anyReady) {
              const firstIssue = buildInfos.flatMap((b: FlashBuildInfo) => b.issues).find(Boolean);
              if (firstIssue) issues.push(firstIssue);
            }

            manifestOk = true;
          }
        } catch (error: any) {
          manifestError = String(error?.message || error);
          issues.push("manifest parse failed");
        }
      } else {
        issues.push("manifest file is missing");
      }

      return {
        id: target.id,
        chip: target.chip,
        label: target.label,
        page: target.page,
        manifest_url: target.manifestUrl,
        manifest_file: manifestFile,
        manifest_exists: manifestExists,
        manifest_ok: manifestOk,
        manifest_error: manifestError || null,
        version: buildVersion || null,
        ready: (manifestOk && buildInfos.length > 0)
          ? buildInfos.some((b) => b.ready)
          : (manifestOk && parts.length > 0 && parts.every((part) => part.file_exists)),
        parts,
        builds: buildInfos.length ? buildInfos : null,
        issues,
      };
    });

    return {
      base_url: base,
      checked_at_ms: nowMs(),
      all_ready: items.every((item) => item.ready),
      items,
    };
  }

  private respondFlashHtml(res: http.ServerResponse, chip: string, label: string, manifestPath: string) {
    let flasherPath = "/flash/index.html";
    if (chip === "portal-cyd") {
      flasherPath = "/flash-portal/index.html";
    } else if (chip === "esp32p4") {
      flasherPath = "/flash-p4/index.html";
    }
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
      .button.disabled { opacity:0.45; pointer-events:none; }
      .diag { margin-top:12px; font-size:13px; color:#b9b9c0; }
      .diag.ok { color:#86efac; }
      .diag.err { color:#fca5a5; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Flash ${label}</h1>
      <p>Use the SODS web flasher to install firmware for ${label}. This page points to the repo-local ESP Web Tools manifest.</p>
      <p>Manifest: <a href="${manifestPath}">${manifestPath}</a></p>
      <a id="open-flasher" class="button" href="${flasherPath}?chip=${chip}">Open Web Flasher</a>
      <div id="diag" class="diag">Checking firmware diagnostics...</div>
    </div>
    <script>
      (async () => {
        const chip = ${JSON.stringify(chip)};
        const chipToId = { esp32: "esp32", esp32c3: "esp32c3", "portal-cyd": "portal-cyd", esp32p4: "esp32p4", p4: "esp32p4" };
        const expectedId = chipToId[chip] || chip;
        const diagEl = document.getElementById("diag");
        const openBtn = document.getElementById("open-flasher");
        try {
          const rsp = await fetch("/api/flash/diagnostics", { cache: "no-store" });
          if (!rsp.ok) throw new Error("diagnostics unavailable");
          const payload = await rsp.json();
          const item = Array.isArray(payload.items) ? payload.items.find((row) => row.id === expectedId) : null;
          if (!item) throw new Error("target diagnostics missing");
          if (item.ready) {
            diagEl.textContent = "Diagnostics: ready";
            diagEl.className = "diag ok";
            return;
          }
          const reason = Array.isArray(item.issues) && item.issues.length ? item.issues[0] : "artifacts are not ready";
          diagEl.textContent = "Diagnostics: not ready (" + reason + ")";
          diagEl.className = "diag err";
          openBtn.classList.add("disabled");
        } catch (error) {
          diagEl.textContent = "Diagnostics: unavailable";
          diagEl.className = "diag err";
          openBtn.classList.add("disabled");
        }
      })();
    </script>
  </body>
</html>`;
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(html);
  }
}
