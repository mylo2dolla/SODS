import http from "node:http";
import { readFileSync, existsSync, statSync, createReadStream, mkdirSync, createWriteStream } from "node:fs";
import { join, resolve } from "node:path";
import { WebSocketServer, WebSocket } from "ws";
import { Ingestor } from "./ingest.js";
import { FrameEngine } from "./frame-engine.js";
import { CanonicalEvent, SignalFrame } from "./schema.js";
import { nowMs } from "./util.js";
import { listTools, runTool } from "./tools.js";

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
    if (url.pathname === "/api/tools") {
      return this.respondJson(res, this.buildToolRegistry());
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
          const result = await runTool(name, input, this.eventBuffer);
          this.respondJson(res, {
            ok: result.ok,
            stdout: result.output,
            stderr: "",
            json: result.data ?? {},
            exitCode: result.ok ? 0 : 1,
          });
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
          const result = await runTool(cmd, args, this.eventBuffer);
          this.respondJson(res, { ok: result.ok, output: result.output, data: result.data ?? {} });
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
          const result = await runTool(name, input, this.eventBuffer);
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

  private buildToolRegistry() {
    try {
      const registryPath = new URL("../../../docs/tool-registry.json", import.meta.url).pathname;
      const raw = JSON.parse(readFileSync(registryPath, "utf8"));
      return raw;
    } catch {
      return { tools: [] };
    }
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
