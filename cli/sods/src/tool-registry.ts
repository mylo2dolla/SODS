import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { findRepoRoot } from "./repo.js";

export type ToolRunnerType = "shell" | "python" | "node" | "builtin";

export type ToolEntry = {
  name: string;
  title?: string;
  description?: string;
  runner: ToolRunnerType;
  entry?: string;
  cwd?: string;
  timeout_ms?: number;
  kind?: "inspect" | "action" | "report" | "runbook" | "passive";
  tags?: string[];
  input_schema?: Record<string, unknown>;
  output?: { format?: "text" | "json" | "url" | "ndjson" };
  scope?: string;
  input?: string;
  output_schema?: Record<string, unknown>;
};

export type ToolRegistryPayload = {
  version?: string;
  policy?: { passive_only?: boolean; notes?: string };
  tools: ToolEntry[];
};

const repoRoot = findRepoRoot(import.meta.url);

function defaultBuiltins(): ToolEntry[] {
  return [
    {
      name: "net.wifi_scan",
      title: "Wi-Fi Scan Start",
      description: "Run a local Wi-Fi scan and return nearby APs.",
      runner: "builtin",
      kind: "action",
      tags: ["net", "wifi", "scan"],
      scope: "godbutton",
      input: "Optional: pattern",
      output: { format: "json" },
    },
    {
      name: "ble.scan_snapshot",
      title: "BLE Scan Snapshot",
      description: "Show current BLE devices seen in the recent window.",
      runner: "builtin",
      kind: "inspect",
      tags: ["ble", "scan"],
      scope: "godbutton",
      input: "Optional: window_ms",
      output: { format: "json" },
    },
    {
      name: "ble.rssi_trend",
      title: "BLE RSSI Trend",
      description: "Show recent BLE RSSI trend for one device or all.",
      runner: "builtin",
      kind: "inspect",
      tags: ["ble", "rssi"],
      scope: "godbutton",
      input: "Optional: device_id",
      output: { format: "json" },
    },
    {
      name: "net.arp",
      title: "ARP Sweep",
      description: "Read ARP table and list discovered local devices.",
      runner: "builtin",
      kind: "inspect",
      tags: ["net", "arp"],
      scope: "godbutton",
      output: { format: "json" },
    },
    {
      name: "net.whoami_rollcall",
      title: "Node Rollcall",
      description: "Probe known/ARP nodes for /whoami responses.",
      runner: "builtin",
      kind: "action",
      tags: ["net", "node"],
      scope: "godbutton",
      input: "Optional: ip_list, timeout_ms",
      output: { format: "json" },
    },
    {
      name: "net.status_snapshot",
      title: "Network Snapshot",
      description: "Collect local interface and SSID snapshot.",
      runner: "builtin",
      kind: "inspect",
      tags: ["net", "status"],
      scope: "godbutton",
      input: "Optional: interface",
      output: { format: "json" },
    },
    {
      name: "net.dhcp_packet",
      title: "DHCP Packet",
      description: "Read DHCP lease packet details for an interface.",
      runner: "builtin",
      kind: "inspect",
      tags: ["net", "dhcp"],
      scope: "tool",
      input: "Required: interface",
      output: { format: "text" },
    },
    {
      name: "net.dns_timing",
      title: "DNS Timing",
      description: "Resolve hostname and report lookup timing.",
      runner: "builtin",
      kind: "inspect",
      tags: ["net", "dns"],
      scope: "tool",
      input: "Required: hostname",
      output: { format: "json" },
    },
    {
      name: "station.portal_state",
      title: "Portal State",
      description: "Fetch current station portal state payload.",
      runner: "builtin",
      kind: "inspect",
      tags: ["station", "portal"],
      scope: "tool",
      input: "Optional: station_url",
      output: { format: "json" },
    },
    {
      name: "station.frames_health",
      title: "Frames Health",
      description: "Summarize emitted frames by source.",
      runner: "builtin",
      kind: "inspect",
      tags: ["station", "frames"],
      scope: "tool",
      input: "Optional: station_url",
      output: { format: "json" },
    },
    {
      name: "portal.flash_targets",
      title: "Flash Targets",
      description: "Return available firmware flashing targets.",
      runner: "builtin",
      kind: "inspect",
      tags: ["portal", "flash"],
      scope: "tool",
      input: "Required: station_url",
      output: { format: "json" },
    },
    {
      name: "p4.status",
      title: "P4 Status",
      description: "Read /status from a P4 node.",
      runner: "builtin",
      kind: "inspect",
      tags: ["p4", "node"],
      scope: "godbutton",
      input: "Required: ip",
      output: { format: "json" },
    },
    {
      name: "p4.god",
      title: "P4 God Trigger",
      description: "Trigger the P4 /god action endpoint.",
      runner: "builtin",
      kind: "action",
      tags: ["p4", "god"],
      scope: "godbutton",
      input: "Required: ip",
      output: { format: "json" },
    },
    {
      name: "camera.viewer",
      title: "Camera Viewer",
      description: "Build camera viewer URL for a target IP/path.",
      runner: "builtin",
      kind: "inspect",
      tags: ["camera"],
      scope: "tool",
      input: "Required: ip, optional: path",
      output: { format: "url" },
    },
    {
      name: "events.activity_snapshot",
      title: "Activity Snapshot",
      description: "Summarize recent event activity by kind/node.",
      runner: "builtin",
      kind: "report",
      tags: ["events", "report"],
      scope: "tool",
      input: "Optional: window_s",
      output: { format: "json" },
    },
    {
      name: "events.replay",
      title: "Replay Ready",
      description: "Prepare replay metadata for a log path.",
      runner: "builtin",
      kind: "action",
      tags: ["events", "replay"],
      scope: "tool",
      input: "Required: path",
      output: { format: "json" },
    },
  ];
}

function readJson(path: string) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function normalizeLegacyTool(tool: any): ToolEntry | null {
  if (!tool?.name) return null;
  const scope = tool.scope || "tool";
  const kind =
    tool.kind === "passive" ? "passive" :
    tool.kind === "active" ? "action" :
    tool.kind;
  return {
    name: tool.name,
    title: tool.title ?? tool.name,
    description: tool.description ?? "",
    runner: "builtin",
    entry: undefined,
    cwd: "${REPO_ROOT}",
    timeout_ms: (typeof tool.timeout_ms === "number" ? tool.timeout_ms : undefined),
    kind,
    tags: [scope],
    scope,
    input: tool.input ?? "",
    output_schema: tool.output_schema,
    output: tool.output ? { format: "text" } : undefined,
  };
}

function normalizeTool(tool: any): ToolEntry | null {
  if (!tool?.name) return null;
  if (tool.runner) return tool as ToolEntry;
  return normalizeLegacyTool(tool);
}

function mergeTools(primary: ToolEntry[], secondary: ToolEntry[]) {
  const map = new Map<string, ToolEntry>();
  for (const t of secondary) map.set(t.name, t);
  for (const t of primary) map.set(t.name, t);
  return Array.from(map.values()).sort((a, b) => a.name.localeCompare(b.name));
}

export function loadToolRegistry(): ToolRegistryPayload {
  const officialPath = join(repoRoot, "docs", "tool-registry.json");
  const userPath = join(repoRoot, "docs", "tool-registry.user.json");
  const officialRaw = readJson(officialPath) ?? { tools: [] };
  const userRaw = readJson(userPath) ?? { tools: [] };
  const officialSeed = Array.isArray(officialRaw.tools) && officialRaw.tools.length > 0
    ? officialRaw.tools
    : defaultBuiltins();
  const officialTools = officialSeed.map(normalizeTool).filter(Boolean) as ToolEntry[];
  const userTools = (userRaw.tools ?? []).map(normalizeTool).filter(Boolean) as ToolEntry[];
  return {
    version: officialRaw.version ?? userRaw.version ?? "1.0",
    policy: officialRaw.policy ?? userRaw.policy ?? { passive_only: false, notes: "Tool names are short labels for God Button + station actions." },
    tools: mergeTools(userTools, officialTools),
  };
}

export function toolRegistryPaths() {
  return {
    repoRoot,
    officialPath: join(repoRoot, "docs", "tool-registry.json"),
    userPath: join(repoRoot, "docs", "tool-registry.user.json"),
    userToolsDir: join(repoRoot, "tools", "user"),
    userLibDir: join(repoRoot, "tools", "user", "lib"),
  };
}
