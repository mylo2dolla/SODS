import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import { CanonicalEvent } from "./schema.js";

export type ToolDef = {
  name: string;
  scope: string;
  input: string;
  output: string;
  kind: "passive" | "active";
};

type RunResult = { ok: boolean; output: string; duration_ms: number };

const tools: ToolDef[] = [
  {
    name: "camera.viewer",
    scope: "camera",
    input: "ip (required), path (optional)",
    output: "URL string",
    kind: "passive",
  },
  {
    name: "net.arp",
    scope: "network",
    input: "none",
    output: "arp table",
    kind: "passive",
  },
  {
    name: "net.dhcp_packet",
    scope: "network",
    input: "interface (required)",
    output: "dhcp packet info",
    kind: "passive",
  },
  {
    name: "net.dns_timing",
    scope: "network",
    input: "hostname (required)",
    output: "resolution ms + addresses",
    kind: "passive",
  },
  {
    name: "ble.rssi_trend",
    scope: "ble",
    input: "device_id (optional)",
    output: "recent RSSI trend",
    kind: "passive",
  },
  {
    name: "events.replay",
    scope: "automation",
    input: "ndjson path (required)",
    output: "replay status",
    kind: "passive",
  },
];

export function listTools(): ToolDef[] {
  return tools;
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
    return { ok: true, output: `http://${ip}${path}`, duration_ms: performance.now() - start };
  }
  if (name === "net.arp") {
    return await runCmd("/usr/sbin/arp", ["-a"], start);
  }
  if (name === "net.dhcp_packet") {
    const iface = input.interface;
    if (!iface) throw new Error("interface is required");
    return await runCmd("/usr/sbin/ipconfig", ["getpacket", iface], start);
  }
  if (name === "net.dns_timing") {
    const hostname = input.hostname;
    if (!hostname) throw new Error("hostname is required");
    const t0 = performance.now();
    const { resolve4 } = await import("node:dns/promises");
    const addrs = await resolve4(hostname);
    const ms = performance.now() - t0;
    return { ok: true, output: `ms=${ms.toFixed(1)} addrs=${addrs.join(",")}`, duration_ms: performance.now() - start };
  }
  if (name === "ble.rssi_trend") {
    const device = input.device_id;
    const points = events
      .filter((e) => e.kind.includes("ble") && (!device || String(e.data?.["device_id"] ?? e.data?.["addr"] ?? "") === device))
      .slice(-50)
      .map((e) => `${e.event_ts} rssi=${e.data?.["rssi"] ?? "?"}`)
      .join("\n");
    return { ok: true, output: points || "no ble events", duration_ms: performance.now() - start };
  }
  if (name === "events.replay") {
    const file = input.path;
    if (!file) throw new Error("path is required");
    return { ok: true, output: `replay-ready path=${file}`, duration_ms: performance.now() - start };
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
