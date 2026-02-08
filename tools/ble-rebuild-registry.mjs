#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { BLEIdentityRegistry } from "../ops/strangelab-control-plane/services/ble/identity-core.mjs";

const DEFAULT_DB_PATH = process.env.BLE_REGISTRY_DB || "/var/lib/strangelab/registry.sqlite";
const DEFAULT_EVENTS_ROOT = process.env.VAULT_EVENTS_ROOT || "/var/sods/vault/events";
const DEFAULT_HOURS = Number(process.env.BLE_REBUILD_HOURS || 24);

function usage() {
  console.log(`Usage:
  node tools/ble-rebuild-registry.mjs [options]

Options:
  --db <path>           SQLite registry path (default: ${DEFAULT_DB_PATH})
  --events-root <path>  Vault events root dir (default: ${DEFAULT_EVENTS_ROOT})
  --hours <n>           Replay lookback hours (default: ${DEFAULT_HOURS})
  --input <path>        Replay one NDJSON file instead of events root
  --verbose             Print per-file progress
  --help                Show this help
`);
}

function parseArgs(argv) {
  const args = {
    db: DEFAULT_DB_PATH,
    eventsRoot: DEFAULT_EVENTS_ROOT,
    hours: Number.isFinite(DEFAULT_HOURS) && DEFAULT_HOURS > 0 ? DEFAULT_HOURS : 24,
    input: "",
    verbose: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--db" && argv[i + 1]) {
      args.db = argv[++i];
      continue;
    }
    if (arg === "--events-root" && argv[i + 1]) {
      args.eventsRoot = argv[++i];
      continue;
    }
    if (arg === "--hours" && argv[i + 1]) {
      const hours = Number(argv[++i]);
      if (!Number.isFinite(hours) || hours <= 0) {
        throw new Error(`invalid --hours: ${argv[i]}`);
      }
      args.hours = hours;
      continue;
    }
    if (arg === "--input" && argv[i + 1]) {
      args.input = argv[++i];
      continue;
    }
    if (arg === "--verbose") {
      args.verbose = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    throw new Error(`unknown arg: ${arg}`);
  }

  return args;
}

function isBleObservationType(type) {
  const value = String(type || "").toLowerCase();
  return value === "ble.observation"
    || value.endsWith(".ble.observation")
    || value.includes("ble.observation.");
}

function collectReplayFiles(eventsRoot, cutoffMs) {
  if (!fs.existsSync(eventsRoot)) return [];
  const entries = fs.readdirSync(eventsRoot, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const dayPath = path.join(eventsRoot, entry.name, "ingest.ndjson");
    if (!fs.existsSync(dayPath)) continue;
    const stat = fs.statSync(dayPath);
    if (stat.mtimeMs < cutoffMs - 12 * 60 * 60 * 1000) continue;
    files.push(dayPath);
  }
  files.sort();
  return files;
}

function readNdjsonLines(filePath, onLine) {
  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    onLine(trimmed);
  }
}

function summarizeUnstableSource(map) {
  const rows = [];
  for (const [key, value] of map.entries()) {
    rows.push({
      source: key,
      distinct_addr_count: value.addresses.size,
      observations: value.count,
      scanner_ids: Array.from(value.scanners).sort(),
    });
  }
  rows.sort((a, b) => {
    if (b.distinct_addr_count !== a.distinct_addr_count) {
      return b.distinct_addr_count - a.distinct_addr_count;
    }
    return b.observations - a.observations;
  });
  return rows.slice(0, 10);
}

function shouldTrackAsUnstable(result) {
  if (!result?.observation) return false;
  const addrType = String(result.observation.addr_type || "").toLowerCase();
  return addrType === "random" || addrType === "resolvable" || addrType === "private";
}

function unstableKey(result) {
  const stable = result?.fingerprints?.fp_stable;
  if (stable) return `fp_stable:${stable}`;
  const company = result?.meta?.company_id ?? "none";
  const name = result?.meta?.name_norm || "unknown";
  return `company:${company}|name:${name}`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cutoffMs = Date.now() - args.hours * 60 * 60 * 1000;
  const replayFiles = args.input ? [args.input] : collectReplayFiles(args.eventsRoot, cutoffMs);

  if (replayFiles.length === 0) {
    throw new Error(args.input
      ? `input file not found: ${args.input}`
      : `no ingest.ndjson files found under ${args.eventsRoot}`);
  }

  const registry = new BLEIdentityRegistry({
    dbPath: args.db,
    reset: true,
    logger: args.verbose ? (line) => console.log(`[ble] ${line}`) : () => {},
  });

  let totalEvents = 0;
  let totalObservations = 0;
  let createdDevices = 0;
  let merges = 0;
  const seenDevices = new Set();
  const unstable = new Map();

  for (const filePath of replayFiles) {
    if (args.verbose) console.log(`Replaying ${filePath}`);
    readNdjsonLines(filePath, (line) => {
      totalEvents += 1;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        return;
      }
      if (!event || typeof event !== "object") return;
      if (!isBleObservationType(event.type)) return;
      const tsMs = Number(event.ts_ms || 0);
      if (tsMs > 0 && tsMs < cutoffMs) return;

      totalObservations += 1;
      const data = event.data && typeof event.data === "object" ? event.data : {};
      const result = registry.processObservation({
        ...data,
        ts_ms: event.ts_ms,
        scanner_id: data.scanner_id || data.node_id || event.src || "unknown",
        src: event.src || "unknown",
      });
      if (!result || result.ignored) return;

      if (!seenDevices.has(result.device_id)) {
        seenDevices.add(result.device_id);
        createdDevices += 1;
      }
      if (result.merged) {
        merges += 1;
      }

      if (shouldTrackAsUnstable(result)) {
        const key = unstableKey(result);
        const row = unstable.get(key) || { count: 0, addresses: new Set(), scanners: new Set() };
        row.count += 1;
        if (result.observation.addr) row.addresses.add(result.observation.addr);
        if (result.observation.scanner_id) row.scanners.add(result.observation.scanner_id);
        unstable.set(key, row);
      }
    });
  }

  const summary = {
    ok: true,
    replay_window_hours: args.hours,
    db_path: args.db,
    events_root: args.eventsRoot,
    replay_files: replayFiles,
    total_events_read: totalEvents,
    total_ble_observations: totalObservations,
    devices_created: createdDevices,
    merges_performed: merges,
    top_unstable_sources: summarizeUnstableSource(unstable),
  };

  console.log(JSON.stringify(summary, null, 2));
}

main().catch((error) => {
  console.error(`ble-rebuild-registry failed: ${String(error?.message || error)}`);
  process.exit(1);
});
