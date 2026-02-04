import http from "node:http";
import { readFileSync, existsSync, statSync, createReadStream } from "node:fs";
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

  constructor(private options: ServerOptions) {
    this.ingestor = new Ingestor(options.piLoggerBase, 500, 1400);
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
}
