import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { CanonicalEvent } from "./schema.js";
import { loadToolRegistry, ToolEntry } from "./tool-registry.js";

export type ToolDef = ToolEntry;

type RunResult = { ok: boolean; output: string; duration_ms: number; data?: Record<string, unknown> };

const repoRoot = resolve(new URL("../../../..", import.meta.url).pathname);

function repoPath(...parts: string[]) {
  return join(repoRoot, ...parts);
}

export function listTools(): ToolDef[] {
  const registry = loadToolRegistry();
  return registry.tools;
}

export async function runTool(
  name: string,
  input: Record<string, string | undefined>,
  events: CanonicalEvent[]
): Promise<RunResult> {
  const start = performance.now();
  if (name === "station.portal_state") {
    const station = input.station_url ?? "http://localhost:9123";
    const res = await fetch(`${station}/api/portal/state`, { method: "GET" });
    if (!res.ok) throw new Error(`station responded ${res.status}`);
    const json = await res.json();
    return { ok: true, output: JSON.stringify(json), data: json, duration_ms: performance.now() - start };
  }
  if (name === "station.frames_health") {
    const station = input.station_url ?? "http://localhost:9123";
    const res = await fetch(`${station}/api/portal/state`, { method: "GET" });
    if (!res.ok) throw new Error(`station responded ${res.status}`);
    const json = await res.json();
    const frames = Array.isArray(json.frames) ? json.frames : [];
    const bySource: Record<string, number> = {};
    for (const f of frames) {
      const src = String(f.source ?? "unknown");
      bySource[src] = (bySource[src] ?? 0) + 1;
    }
    const data = { frames: frames.length, by_source: bySource };
    return { ok: true, output: JSON.stringify(data), data, duration_ms: performance.now() - start };
  }
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
  if (name === "net.status_snapshot") {
    const iface = input.interface ?? "en0";
    const ifconfig = await runCmd("/sbin/ifconfig", [iface], start);
    let wifi = "";
    try {
      const wifiResult = await runCmd("/usr/sbin/networksetup", ["-getairportnetwork", iface], start);
      wifi = wifiResult.output;
    } catch {
      wifi = "networksetup unavailable";
    }
    const output = [wifi, ifconfig.output].join("\n");
    return { ok: true, output, data: { wifi, ifconfig: ifconfig.output }, duration_ms: performance.now() - start };
  }
  if (name === "net.wifi_scan") {
    const pattern = input.pattern;
    const script = repoPath("tools", "wifi-scan.sh");
    if (!existsSync(script)) throw new Error(`wifi-scan helper not found at ${script}`);
    const args = pattern ? [pattern] : [];
    const result = await runCmd(script, args, start);
    return { ...result, data: { lines: result.output.split("\n").filter(Boolean) } };
  }
  if (name === "net.whoami_rollcall") {
    const timeoutRaw = Number(input.timeout_ms ?? 0);
    const timeoutMs = Number.isFinite(timeoutRaw) ? timeoutRaw : 0;
    const list = (input.ip_list ?? "") as string;
    let ips = list.split(",").map((v) => v.trim()).filter(Boolean);
    if (ips.length === 0) {
      const arp = await runCmd("/usr/sbin/arp", ["-a"], start);
      ips = arp.output
        .split("\n")
        .map((line) => {
          const match = line.match(/(\d{1,3}\.){3}\d{1,3}/);
          return match ? match[0] : "";
        })
        .filter(Boolean);
    }
    const results: Record<string, string> = {};
    for (const ip of ips.slice(0, 64)) {
      try {
        if (timeoutMs > 0) {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), timeoutMs);
          const res = await fetch(`http://${ip}/whoami`, { method: "GET", signal: controller.signal });
          if (timer) clearTimeout(timer);
          results[ip] = res.ok ? await res.text() : `HTTP ${res.status}`;
        } else {
          const res = await fetch(`http://${ip}/whoami`, { method: "GET" });
          results[ip] = res.ok ? await res.text() : `HTTP ${res.status}`;
        }
      } catch {
        results[ip] = "unreachable";
      }
    }
    return { ok: true, output: JSON.stringify(results, null, 2), data: { results }, duration_ms: performance.now() - start };
  }
  if (name === "portal.flash_targets") {
    const station = input.station_url;
    if (!station) throw new Error("station_url is required");
    const res = await fetch(`${station}/api/flash`, { method: "GET" });
    if (!res.ok) throw new Error(`station responded ${res.status}`);
    const json = await res.json();
    return { ok: true, output: JSON.stringify(json), data: json, duration_ms: performance.now() - start };
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
  if (name === "ble.scan_snapshot") {
    const windowMs = Number(input.window_ms ?? "15000");
    const cutoff = Date.now() - windowMs;
    const seen = new Map<string, { last: string; rssi: unknown }>();
    for (const ev of events) {
      if (!ev.kind.includes("ble")) continue;
      const ts = Date.parse(ev.event_ts);
      if (Number.isFinite(ts) && ts < cutoff) continue;
      const id = String(ev.data?.["device_id"] ?? ev.data?.["addr"] ?? "");
      if (!id) continue;
      const last = ev.event_ts;
      const rssi = ev.data?.["rssi"];
      seen.set(id, { last, rssi });
    }
    const items = Array.from(seen.entries()).map(([id, info]) => ({ id, last_seen: info.last, rssi: info.rssi }));
    return { ok: true, output: JSON.stringify(items, null, 2), data: { items }, duration_ms: performance.now() - start };
  }
  if (name === "events.activity_snapshot") {
    const windowS = Number(input.window_s ?? "30");
    const cutoff = Date.now() - windowS * 1000;
    const byKind: Record<string, number> = {};
    const byNode: Record<string, number> = {};
    for (const ev of events) {
      const ts = Date.parse(ev.event_ts);
      if (Number.isFinite(ts) && ts < cutoff) continue;
      byKind[ev.kind] = (byKind[ev.kind] ?? 0) + 1;
      byNode[ev.node_id] = (byNode[ev.node_id] ?? 0) + 1;
    }
    const data = { window_s: windowS, by_kind: byKind, by_node: byNode };
    return { ok: true, output: JSON.stringify(data, null, 2), data, duration_ms: performance.now() - start };
  }
  if (name === "events.replay") {
    const file = input.path;
    if (!file) throw new Error("path is required");
    return { ok: true, output: `replay-ready path=${file}`, data: { path: file, status: "replay-ready" }, duration_ms: performance.now() - start };
  }
  throw new Error("unknown tool");
}

function runCmd(cmd: string, args: string[], start: number, timeoutMs: number = 0): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args);
    let out = "";
    let err = "";
    const timer = timeoutMs > 0 ? setTimeout(() => {
      child.kill();
      resolve({ ok: false, output: "timeout", duration_ms: performance.now() - start });
    }, timeoutMs) : null;
    child.stdout.on("data", (d) => (out += d.toString()));
    child.stderr.on("data", (d) => (err += d.toString()));
    child.on("error", (e) => {
      if (timer) clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      if (timer) clearTimeout(timer);
      const output = out.trim() || err.trim() || `exit ${code}`;
      resolve({ ok: code === 0, output, duration_ms: performance.now() - start });
    });
  });
}
