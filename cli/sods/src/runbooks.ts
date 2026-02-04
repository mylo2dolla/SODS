import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { findRepoRoot } from "./repo.js";

export type RunbookStep = {
  id: string;
  tool: string;
  input?: Record<string, unknown>;
};

export type RunbookParallel = {
  parallel: RunbookStep[];
};

export type RunbookEntry = {
  id: string;
  title?: string;
  description?: string;
  kind?: "runbook";
  vars?: Record<string, unknown>;
  steps?: Array<RunbookStep | RunbookParallel>;
  tags?: string[];
  ui?: { capsule?: boolean; icon?: string; color?: string };
  input_schema?: Record<string, unknown>;
};

export type RunbookRegistryPayload = {
  version?: string;
  runbooks: RunbookEntry[];
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

function mergeRunbooks(primary: RunbookEntry[], secondary: RunbookEntry[]) {
  const map = new Map<string, RunbookEntry>();
  for (const r of secondary) map.set(r.id, r);
  for (const r of primary) map.set(r.id, r);
  return Array.from(map.values()).sort((a, b) => a.id.localeCompare(b.id));
}

export function loadRunbooks(): RunbookRegistryPayload {
  const officialPath = join(repoRoot, "docs", "runbooks.json");
  const userPath = join(repoRoot, "docs", "runbooks.user.json");
  const officialRaw = readJson(officialPath) ?? { runbooks: [] };
  const userRaw = readJson(userPath) ?? { runbooks: [] };
  const officialRunbooks = officialRaw.runbooks ?? [];
  const userRunbooks = userRaw.runbooks ?? [];
  return {
    version: officialRaw.version ?? userRaw.version ?? "1.0",
    runbooks: mergeRunbooks(userRunbooks, officialRunbooks),
  };
}

export function runbookRegistryPaths() {
  return {
    officialPath: join(repoRoot, "docs", "runbooks.json"),
    userPath: join(repoRoot, "docs", "runbooks.user.json"),
  };
}
