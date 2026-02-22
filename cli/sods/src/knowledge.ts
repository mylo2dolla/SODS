import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type KnowledgeField =
  | "display_label"
  | "hostname"
  | "ip"
  | "mac"
  | "vendor"
  | "vendor_confidence_score"
  | "open_ports"
  | "http_url"
  | "rtsp_uri"
  | "onvif_xaddr"
  | "node_id"
  | "ble_company"
  | "last_seen_ms";

export type KnowledgeSecretField = "onvif_username" | "onvif_password" | "rtsp_username" | "rtsp_password";

export type KnowledgeSource =
  | "manual.override"
  | "user.credential"
  | "probe.onvif"
  | "probe.rtsp"
  | "scan.network.live"
  | "scan.ble.live"
  | "station.registry"
  | "station.alias"
  | "export.snapshot"
  | "evidence.payload"
  | "audit.log"
  | "event.derived";

export type KnowledgeValue = string | number | number[];

export type KnowledgeClaim = {
  value: KnowledgeValue;
  source: KnowledgeSource;
  confidence: number;
  updated_at_ms: number;
};

export type KnowledgeEntity = {
  key: string;
  facts: Partial<Record<KnowledgeField, KnowledgeClaim>>;
  updated_at_ms: number;
};

export type KnowledgeSnapshot = {
  version: number;
  revision: number;
  updated_at_ms: number;
  entities: Record<string, KnowledgeEntity>;
};

export type KnowledgeUpsert = {
  entity_key: string;
  field: KnowledgeField;
  value: KnowledgeValue;
  source: KnowledgeSource;
  confidence: number;
  updated_at_ms?: number;
};

export type KnowledgeDelete = {
  entity_key: string;
  field: KnowledgeField;
};

export type KnowledgeResolvedField = {
  entity_key: string;
  field: KnowledgeField;
  value: KnowledgeValue;
  source: KnowledgeSource;
  confidence: number;
  updated_at_ms: number;
  auto_use: boolean;
};

export type KnowledgeResolveResult = {
  results: KnowledgeResolvedField[];
  by_field: Partial<Record<KnowledgeField, KnowledgeResolvedField>>;
};

const SOURCE_PRECEDENCE: Record<KnowledgeSource, number> = {
  "manual.override": 120,
  "user.credential": 110,
  "probe.onvif": 100,
  "probe.rtsp": 90,
  "scan.network.live": 80,
  "scan.ble.live": 70,
  "station.registry": 60,
  "station.alias": 50,
  "export.snapshot": 40,
  "evidence.payload": 30,
  "audit.log": 20,
  "event.derived": 10,
};

const AUTO_USE_CONFIDENCE_THRESHOLD = 50;

export function knowledgeSnapshotPath() {
  const env = process.env.SODS_KNOWLEDGE_PATH?.trim();
  if (env) return env;
  return "/Users/letsdev/Library/Application Support/LvlUpKit/SharedKnowledge/facts.v1.json";
}

export function knowledgeLockPath(snapshotPath = knowledgeSnapshotPath()) {
  const env = process.env.SODS_KNOWLEDGE_LOCK_PATH?.trim();
  if (env) return env;
  return join(dirname(snapshotPath), "facts.v1.lock");
}

function nowMs() {
  return Date.now();
}

export function normalizeKnowledgeEntityKey(raw: string) {
  return String(raw ?? "").trim().toLowerCase();
}

export function knowledgeEntityKeyForIP(ip: string) {
  return `ip:${normalizeKnowledgeEntityKey(ip)}`;
}

export function knowledgeEntityKeyForNode(nodeID: string) {
  return `node:${normalizeKnowledgeEntityKey(nodeID)}`;
}

export function knowledgeEntityKeyFromAliasIdentifier(identifier: string) {
  const key = normalizeKnowledgeEntityKey(identifier);
  if (!key) return key;
  if (key.startsWith("node:")) return key;
  if (looksLikeIPv4(key)) return knowledgeEntityKeyForIP(key);
  if (looksLikeMAC(key)) return `mac:${key}`;
  return key;
}

export function looksLikeIPv4(raw: string) {
  const parts = raw.split(".");
  if (parts.length !== 4) return false;
  return parts.every((part) => {
    if (!part) return false;
    const parsed = Number(part);
    return Number.isInteger(parsed) && parsed >= 0 && parsed <= 255;
  });
}

export function looksLikeMAC(raw: string) {
  const normalized = raw.replace(/-/g, ":");
  const parts = normalized.split(":");
  if (parts.length !== 6) return false;
  return parts.every((part) => /^[0-9a-f]{2}$/i.test(part));
}

export function loadKnowledgeSnapshot(path = knowledgeSnapshotPath()): KnowledgeSnapshot {
  if (!existsSync(path)) {
    return emptySnapshot();
  }

  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    const entitiesRaw = parsed.entities && typeof parsed.entities === "object" ? parsed.entities : {};
    const entities: Record<string, KnowledgeEntity> = {};

    for (const [rawKey, rawEntity] of Object.entries(entitiesRaw)) {
      if (!rawEntity || typeof rawEntity !== "object") continue;
      const key = normalizeKnowledgeEntityKey(rawKey);
      if (!key) continue;

      const factsRaw = (rawEntity as any).facts;
      const facts: Partial<Record<KnowledgeField, KnowledgeClaim>> = {};
      if (factsRaw && typeof factsRaw === "object") {
        for (const [fieldRaw, rawClaim] of Object.entries(factsRaw)) {
          if (!isKnowledgeField(fieldRaw)) continue;
          if (!rawClaim || typeof rawClaim !== "object") continue;
          const source = String((rawClaim as any).source ?? "event.derived") as KnowledgeSource;
          if (!isKnowledgeSource(source)) continue;

          const claim: KnowledgeClaim = {
            value: sanitizeKnowledgeValue((rawClaim as any).value),
            source,
            confidence: clampConfidence(Number((rawClaim as any).confidence ?? 0)),
            updated_at_ms: positiveInt((rawClaim as any).updated_at_ms, 0),
          };
          facts[fieldRaw] = claim;
        }
      }

      entities[key] = {
        key,
        facts,
        updated_at_ms: positiveInt((rawEntity as any).updated_at_ms, 0),
      };
    }

    return {
      version: positiveInt(parsed.version, 1) || 1,
      revision: positiveInt(parsed.revision, 0),
      updated_at_ms: positiveInt(parsed.updated_at_ms, 0),
      entities,
    };
  } catch {
    return emptySnapshot();
  }
}

export function upsertKnowledgeFacts(
  upserts: KnowledgeUpsert[],
  options: { snapshotPath?: string; lockPath?: string } = {}
): KnowledgeSnapshot {
  if (!upserts.length) {
    return loadKnowledgeSnapshot(options.snapshotPath);
  }

  const snapshotPath = options.snapshotPath ?? knowledgeSnapshotPath();
  const lockPath = options.lockPath ?? knowledgeLockPath(snapshotPath);

  return withKnowledgeLock(lockPath, () => {
    let snapshot = loadKnowledgeSnapshot(snapshotPath);
    let changed = false;

    for (const upsert of upserts) {
      if (!upsert || !isKnowledgeField(upsert.field) || !isKnowledgeSource(upsert.source)) continue;
      const entityKey = normalizeKnowledgeEntityKey(upsert.entity_key);
      if (!entityKey) continue;

      const entity: KnowledgeEntity = snapshot.entities[entityKey] ?? {
        key: entityKey,
        facts: {},
        updated_at_ms: 0,
      };

      const incoming: KnowledgeClaim = {
        value: sanitizeKnowledgeValue(upsert.value),
        source: upsert.source,
        confidence: clampConfidence(upsert.confidence),
        updated_at_ms: positiveInt(upsert.updated_at_ms, nowMs()),
      };

      const existing = entity.facts[upsert.field];
      if (!existing || incomingPreferred(existing, incoming)) {
        entity.facts[upsert.field] = incoming;
        entity.updated_at_ms = Math.max(entity.updated_at_ms, incoming.updated_at_ms);
        snapshot.entities[entityKey] = entity;
        changed = true;
      }
    }

    if (!changed) {
      return snapshot;
    }

    snapshot = {
      ...snapshot,
      revision: positiveInt(snapshot.revision, 0) + 1,
      updated_at_ms: nowMs(),
    };
    writeKnowledgeSnapshot(snapshot, snapshotPath);
    return snapshot;
  });
}

export function deleteKnowledgeFacts(
  deletions: KnowledgeDelete[],
  options: { snapshotPath?: string; lockPath?: string } = {}
): KnowledgeSnapshot {
  if (!deletions.length) {
    return loadKnowledgeSnapshot(options.snapshotPath);
  }

  const snapshotPath = options.snapshotPath ?? knowledgeSnapshotPath();
  const lockPath = options.lockPath ?? knowledgeLockPath(snapshotPath);

  return withKnowledgeLock(lockPath, () => {
    let snapshot = loadKnowledgeSnapshot(snapshotPath);
    let changed = false;

    for (const deletion of deletions) {
      if (!deletion || !isKnowledgeField(deletion.field)) continue;
      const entityKey = normalizeKnowledgeEntityKey(deletion.entity_key);
      if (!entityKey) continue;
      const entity = snapshot.entities[entityKey];
      if (!entity) continue;

      if (entity.facts[deletion.field] != null) {
        delete entity.facts[deletion.field];
        entity.updated_at_ms = nowMs();
        changed = true;
      }

      if (Object.keys(entity.facts).length === 0) {
        delete snapshot.entities[entityKey];
      } else {
        snapshot.entities[entityKey] = entity;
      }
    }

    if (!changed) {
      return snapshot;
    }

    snapshot = {
      ...snapshot,
      revision: positiveInt(snapshot.revision, 0) + 1,
      updated_at_ms: nowMs(),
    };
    writeKnowledgeSnapshot(snapshot, snapshotPath);
    return snapshot;
  });
}

export function resolveKnowledge(
  keys: string[],
  fields: KnowledgeField[],
  options: { snapshotPath?: string; requireAutoUse?: boolean } = {}
): KnowledgeResolveResult {
  const snapshot = loadKnowledgeSnapshot(options.snapshotPath);
  const normalizedKeys = dedupe(keys.map((value) => normalizeKnowledgeEntityKey(value)).filter(Boolean));
  const normalizedFields = dedupe(fields.filter((field) => isKnowledgeField(field)));
  const results: KnowledgeResolvedField[] = [];
  const byField: Partial<Record<KnowledgeField, KnowledgeResolvedField>> = {};

  for (const field of normalizedFields) {
    let selected: KnowledgeResolvedField | null = null;

    for (const key of normalizedKeys) {
      const claim = snapshot.entities[key]?.facts[field];
      if (!claim) continue;
      const candidate: KnowledgeResolvedField = {
        entity_key: key,
        field,
        value: claim.value,
        source: claim.source,
        confidence: claim.confidence,
        updated_at_ms: claim.updated_at_ms,
        auto_use: claim.confidence >= AUTO_USE_CONFIDENCE_THRESHOLD,
      };

      if (options.requireAutoUse && !candidate.auto_use) {
        continue;
      }

      if (!selected || incomingPreferred(selectedToClaim(selected), selectedToClaim(candidate))) {
        selected = candidate;
      }
    }

    if (selected) {
      results.push(selected);
      byField[field] = selected;
    }
  }

  return { results, by_field: byField };
}

export function knowledgeEntity(
  key: string,
  options: { snapshotPath?: string } = {}
): KnowledgeEntity | null {
  const normalized = normalizeKnowledgeEntityKey(key);
  if (!normalized) return null;
  const snapshot = loadKnowledgeSnapshot(options.snapshotPath);
  return snapshot.entities[normalized] ?? null;
}

export function importAliasMapsIntoKnowledge(options: { repoRoot?: string } = {}) {
  const repoRoot = options.repoRoot ?? resolve(fileURLToPath(new URL("../../..", import.meta.url)));
  const officialPath = join(repoRoot, "docs", "aliases.json");
  const userPath = join(repoRoot, "docs", "aliases.user.json");

  const official = readAliasMap(officialPath);
  const user = readAliasMap(userPath);

  const now = nowMs();
  const upserts: KnowledgeUpsert[] = [];

  for (const [id, alias] of Object.entries(official)) {
    const trimmedAlias = String(alias ?? "").trim();
    if (!trimmedAlias) continue;
    upserts.push({
      entity_key: knowledgeEntityKeyFromAliasIdentifier(id),
      field: "display_label",
      value: trimmedAlias,
      source: "station.alias",
      confidence: 75,
      updated_at_ms: now,
    });
  }

  for (const [id, alias] of Object.entries(user)) {
    const trimmedAlias = String(alias ?? "").trim();
    if (!trimmedAlias) continue;
    upserts.push({
      entity_key: knowledgeEntityKeyFromAliasIdentifier(id),
      field: "display_label",
      value: trimmedAlias,
      source: "manual.override",
      confidence: 100,
      updated_at_ms: now,
    });
  }

  if (!upserts.length) {
    return { imported: 0 };
  }

  upsertKnowledgeFacts(upserts);
  return { imported: upserts.length };
}

function writeKnowledgeSnapshot(snapshot: KnowledgeSnapshot, path: string) {
  mkdirSync(dirname(path), { recursive: true });
  const tempPath = `${path}.tmp.${process.pid}.${Date.now()}`;
  writeFileSync(tempPath, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
  renameSync(tempPath, path);
}

function emptySnapshot(): KnowledgeSnapshot {
  return {
    version: 1,
    revision: 0,
    updated_at_ms: 0,
    entities: {},
  };
}

function withKnowledgeLock<T>(lockPath: string, action: () => T): T {
  const release = acquireLock(lockPath);
  try {
    return action();
  } finally {
    release();
  }
}

function acquireLock(lockPath: string) {
  mkdirSync(dirname(lockPath), { recursive: true });

  const timeoutMs = 3000;
  const staleMs = 60_000;
  const start = nowMs();

  while (true) {
    try {
      const fd = openSync(lockPath, "wx", 0o600);
      return () => {
        try {
          closeSync(fd);
        } catch {
          // ignore
        }
        try {
          unlinkSync(lockPath);
        } catch {
          // ignore
        }
      };
    } catch (error: any) {
      if (error?.code !== "EEXIST") {
        throw error;
      }

      if (existsSync(lockPath)) {
        try {
          const age = nowMs() - statSync(lockPath).mtimeMs;
          if (age > staleMs) {
            unlinkSync(lockPath);
            continue;
          }
        } catch {
          // ignore stat/remove races
        }
      }

      if (nowMs() - start > timeoutMs) {
        throw new Error(`Timed out acquiring knowledge lock: ${lockPath}`);
      }
      sleepSync(20);
    }
  }
}

const sleepBuffer = new SharedArrayBuffer(4);
const sleepArray = new Int32Array(sleepBuffer);

function sleepSync(ms: number) {
  Atomics.wait(sleepArray, 0, 0, ms);
}

function incomingPreferred(existing: KnowledgeClaim, incoming: KnowledgeClaim) {
  const existingRank = SOURCE_PRECEDENCE[existing.source] ?? 0;
  const incomingRank = SOURCE_PRECEDENCE[incoming.source] ?? 0;

  if (incomingRank !== existingRank) {
    return incomingRank > existingRank;
  }
  if (incoming.confidence !== existing.confidence) {
    return incoming.confidence > existing.confidence;
  }
  if (incoming.updated_at_ms !== existing.updated_at_ms) {
    return incoming.updated_at_ms > existing.updated_at_ms;
  }
  return false;
}

function selectedToClaim(value: KnowledgeResolvedField): KnowledgeClaim {
  return {
    value: value.value,
    source: value.source,
    confidence: value.confidence,
    updated_at_ms: value.updated_at_ms,
  };
}

function clampConfidence(value: number) {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, Math.round(value)));
}

function positiveInt(value: unknown, fallback: number) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) return fallback;
  return Math.floor(parsed);
}

function sanitizeKnowledgeValue(value: unknown): KnowledgeValue {
  if (typeof value === "string") return value;
  if (typeof value === "number") return Number.isFinite(value) ? Math.round(value) : 0;
  if (Array.isArray(value)) {
    return value.map((item) => {
      const parsed = Number(item);
      return Number.isFinite(parsed) ? Math.round(parsed) : 0;
    });
  }
  return String(value ?? "");
}

function isKnowledgeField(value: string): value is KnowledgeField {
  return [
    "display_label",
    "hostname",
    "ip",
    "mac",
    "vendor",
    "vendor_confidence_score",
    "open_ports",
    "http_url",
    "rtsp_uri",
    "onvif_xaddr",
    "node_id",
    "ble_company",
    "last_seen_ms",
  ].includes(value);
}

function isKnowledgeSource(value: string): value is KnowledgeSource {
  return Object.prototype.hasOwnProperty.call(SOURCE_PRECEDENCE, value);
}

function dedupe<T>(items: T[]): T[] {
  return Array.from(new Set(items));
}

function readAliasMap(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    const aliases = parsed?.aliases && typeof parsed.aliases === "object" ? parsed.aliases : parsed;
    if (!aliases || typeof aliases !== "object") return {};
    const out: Record<string, string> = {};
    for (const [key, value] of Object.entries(aliases)) {
      if (typeof value === "string" && value.trim()) {
        out[key] = value.trim();
      }
    }
    return out;
  } catch {
    return {};
  }
}

export function knowledgeSummaryLabel(result: KnowledgeResolvedField | null | undefined) {
  if (!result) return "unknown";
  return `${result.source} (${result.confidence})`;
}

export function defaultKnowledgePaths() {
  return {
    snapshotPath: knowledgeSnapshotPath(),
    lockPath: knowledgeLockPath(),
    keychainService: process.env.SODS_KNOWLEDGE_KEYCHAIN_SERVICE?.trim() || "com.lvlupkit.shared-knowledge.v1",
    home: os.homedir(),
  };
}
