import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { findRepoRoot } from "./repo.js";

export type PresetKind = "single" | "macro";

export type PresetEntry = {
  id: string;
  title?: string;
  description?: string;
  kind: PresetKind;
  tool?: string;
  input?: Record<string, unknown>;
  ui?: { icon?: string; color?: string; capsule?: boolean };
  vars?: Record<string, unknown>;
  steps?: Array<any>;
  tags?: string[];
};

export type PresetRegistryPayload = {
  version?: string;
  presets: PresetEntry[];
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

function mergePresets(primary: PresetEntry[], secondary: PresetEntry[]) {
  const map = new Map<string, PresetEntry>();
  for (const p of secondary) map.set(p.id, p);
  for (const p of primary) map.set(p.id, p);
  return Array.from(map.values()).sort((a, b) => a.id.localeCompare(b.id));
}

export function loadPresets(): PresetRegistryPayload {
  const officialPath = join(repoRoot, "docs", "presets.json");
  const userPath = join(repoRoot, "docs", "presets.user.json");
  const officialRaw = readJson(officialPath) ?? { presets: [] };
  const userRaw = readJson(userPath) ?? { presets: [] };
  const officialPresets = officialRaw.presets ?? [];
  const userPresets = userRaw.presets ?? [];
  return {
    version: officialRaw.version ?? userRaw.version ?? "1.0",
    presets: mergePresets(userPresets, officialPresets),
  };
}

export function presetRegistryPaths() {
  return {
    repoRoot,
    officialPath: join(repoRoot, "docs", "presets.json"),
    userPath: join(repoRoot, "docs", "presets.user.json"),
  };
}
