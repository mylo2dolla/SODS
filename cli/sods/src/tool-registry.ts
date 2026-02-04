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
  const officialTools = (officialRaw.tools ?? []).map(normalizeTool).filter(Boolean) as ToolEntry[];
  const userTools = (userRaw.tools ?? []).map(normalizeTool).filter(Boolean) as ToolEntry[];
  return {
    version: officialRaw.version ?? userRaw.version ?? "1.0",
    policy: officialRaw.policy ?? userRaw.policy,
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
