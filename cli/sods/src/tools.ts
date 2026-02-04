import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import { readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { CanonicalEvent } from "./schema.js";

export type ToolDef = {
  name: string;
  scope: string;
  input: string;
  output: string;
  kind: "passive" | "active";
  description?: string;
  output_schema?: Record<string, unknown>;
};

type RunResult = { ok: boolean; output: string; duration_ms: number; data?: Record<string, unknown> };

function findRepoRoot() {
  let dir = resolve(fileURLToPath(new URL(".", import.meta.url)));
  for (let i = 0; i < 6; i += 1) {
    const toolsPath = join(dir, "tools", "_sods_cli.sh");
    const cliPath = join(dir, "cli", "sods");
    if (existsSync(toolsPath) && existsSync(cliPath)) return dir;
    const parent = resolve(dir, "..");
    if (parent === dir) break;
    dir = parent;
  }
  return resolve(fileURLToPath(new URL("../../../..", import.meta.url)));
}

const repoRoot = findRepoRoot();

function repoPath(...parts: string[]) {
  return join(repoRoot, ...parts);
}

export function listTools(): ToolDef[] {
  const registryPath = new URL("../../../docs/tool-registry.json", import.meta.url).pathname;
  if (!existsSync(registryPath)) return [];
  try {
    const raw = JSON.parse(readFileSync(registryPath, "utf8"));
    if (Array.isArray(raw.tools)) {
      const list = raw.tools as ToolDef[];
      return list.filter((tool) => tool.kind === "passive");
    }
  } catch {
    return [];
  }
  return [];
}

export async function runTool(
  name: string,
  input: Record<string, string | undefined>,
  events: CanonicalEvent[]
): Promise<RunResult> {
  const start = performance.now();
  if (name === "camera.viewer") {
    const ip = input.ip;
    if (!ip) throw new Error("ip is required");
    const path = input.path ?? "/";
    const url = `http://${ip}${path}`;
    return { ok: true, output: url, data: { url }, duration_ms: performance.now() - start };
  }
  if (name === "net.arp") {
    const result = await runCmd("/usr/sbin/arp", ["-a"], start);
    return { ...result, data: { lines: result.output.split("\n").filter(Boolean) } };
  }
  if (name === "net.dhcp_packet") {
    const iface = input.interface;
    if (!iface) throw new Error("interface is required");
    const result = await runCmd("/usr/sbin/ipconfig", ["getpacket", iface], start);
    return { ...result, data: { packet: result.output } };
  }
  if (name === "net.dns_timing") {
    const hostname = input.hostname;
    if (!hostname) throw new Error("hostname is required");
    const t0 = performance.now();
    const { resolve4 } = await import("node:dns/promises");
    const addrs = await resolve4(hostname);
    const ms = performance.now() - t0;
    return { ok: true, output: `ms=${ms.toFixed(1)} addrs=${addrs.join(",")}`, data: { ms: Number(ms.toFixed(1)), addrs }, duration_ms: performance.now() - start };
  }
  if (name === "net.wifi_scan") {
    const pattern = input.pattern;
    const script = repoPath("tools", "wifi-scan.sh");
    if (!existsSync(script)) throw new Error(`wifi-scan helper not found at ${script}`);
    const args = pattern ? [pattern] : [];
    const result = await runCmd(script, args, start);
    return { ...result, data: { lines: result.output.split("\n").filter(Boolean) } };
  }
  if (name === "ble.rssi_trend") {
    const device = input.device_id;
    const points = events
      .filter((e) => e.kind.includes("ble") && (!device || String(e.data?.["device_id"] ?? e.data?.["addr"] ?? "") === device))
      .slice(-50)
      .map((e) => `${e.event_ts} rssi=${e.data?.["rssi"] ?? "?"}`)
      .join("\n");
    return { ok: true, output: points || "no ble events", data: { points: points ? points.split("\n") : [] }, duration_ms: performance.now() - start };
  }
  if (name === "events.replay") {
    const file = input.path;
    if (!file) throw new Error("path is required");
    return { ok: true, output: `replay-ready path=${file}`, data: { path: file, status: "replay-ready" }, duration_ms: performance.now() - start };
  }
  throw new Error("unknown tool");
}

function runCmd(cmd: string, args: string[], start: number): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args);
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill();
      resolve({ ok: false, output: "timeout", duration_ms: performance.now() - start });
    }, 2000);
    child.stdout.on("data", (d) => (out += d.toString()));
    child.stderr.on("data", (d) => (err += d.toString()));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const output = out.trim() || err.trim() || `exit ${code}`;
      resolve({ ok: code === 0, output, duration_ms: performance.now() - start });
    });
  });
}
