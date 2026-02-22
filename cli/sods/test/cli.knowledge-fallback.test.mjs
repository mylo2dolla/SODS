import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const cliDir = path.resolve(__dirname, "..");

function runCLI(args, { env = process.env, timeoutMS = 15_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["dist/cli.js", ...args], {
      cwd: cliDir,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMS);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({
        status: code,
        signal,
        stdout,
        stderr: timedOut ? `${stderr}\nTIMED_OUT` : stderr,
      });
    });
  });
}

function startMockServer() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url || "/", "http://127.0.0.1:0");

    if (url.pathname === "/v1/events") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ items: [] }));
      return;
    }

    if (url.pathname === "/api/aliases") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ aliases: {} }));
      return;
    }

    if (url.pathname === "/api/knowledge/resolve") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        results: [
          {
            entity_key: "node:test-node",
            field: "ip",
            value: "10.12.0.9",
            source: "station.registry",
            confidence: 88,
            updated_at_ms: Date.now(),
            auto_use: true,
          },
          {
            entity_key: "node:test-node",
            field: "display_label",
            value: "lab-node",
            source: "station.alias",
            confidence: 75,
            updated_at_ms: Date.now(),
            auto_use: true,
          },
          {
            entity_key: "node:test-node",
            field: "http_url",
            value: "http://10.12.0.9:8080",
            source: "station.registry",
            confidence: 82,
            updated_at_ms: Date.now(),
            auto_use: true,
          },
        ],
        by_field: {
          ip: {
            entity_key: "node:test-node",
            field: "ip",
            value: "10.12.0.9",
            source: "station.registry",
            confidence: 88,
            updated_at_ms: Date.now(),
            auto_use: true,
          },
          display_label: {
            entity_key: "node:test-node",
            field: "display_label",
            value: "lab-node",
            source: "station.alias",
            confidence: 75,
            updated_at_ms: Date.now(),
            auto_use: true,
          },
          http_url: {
            entity_key: "node:test-node",
            field: "http_url",
            value: "http://10.12.0.9:8080",
            source: "station.registry",
            confidence: 82,
            updated_at_ms: Date.now(),
            auto_use: true,
          },
        },
      }));
      return;
    }

    if (url.pathname === "/api/knowledge/upsert" && req.method === "POST") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, revision: 1, upserted: 1, deleted: 0 }));
      return;
    }

    if ((url.pathname === "/api/aliases/user/set" || url.pathname === "/api/aliases/user/delete") && req.method === "POST") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("ok");
      return;
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({
        server,
        port: address.port,
      });
    });
  });
}

test("whereis falls back to shared knowledge when live events are missing", async () => {
  const { server, port } = await startMockServer();
  const base = `http://127.0.0.1:${port}`;

  try {
    const run = await runCLI(["whereis", "test-node", "--station", base, "--logger", base], {
      env: { ...process.env },
    });

    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /alias:\s+lab-node/);
    assert.match(run.stdout, /ip:\s+10\.12\.0\.9/);
    assert.match(run.stdout, /kind:\s+knowledge\.resolve/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("open falls back to shared knowledge and prints known urls", async () => {
  const { server, port } = await startMockServer();
  const base = `http://127.0.0.1:${port}`;

  try {
    const run = await runCLI(["open", "test-node", "--station", base, "--logger", base], {
      env: { ...process.env, SODS_DISABLE_OPEN: "1" },
    });

    assert.equal(run.status, 0, run.stderr || run.stdout);
    assert.match(run.stdout, /alias:\s+lab-node/);
    assert.match(run.stdout, /http:\/\/10\.12\.0\.9:8080/);
    assert.match(run.stdout, /http:\/\/10\.12\.0\.9\/health/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
