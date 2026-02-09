import express from "express";
import fs from "node:fs";
import path from "node:path";

let BLEIdentityRegistry = null;
let mapMergedEvent = null;
let mapSeenEvent = null;

try {
  ({ BLEIdentityRegistry, mapMergedEvent, mapSeenEvent } = await import("../services/ble/identity-core.mjs"));
} catch {
  try {
    ({ BLEIdentityRegistry, mapMergedEvent, mapSeenEvent } = await import("./services/ble/identity-core.mjs"));
  } catch {
    BLEIdentityRegistry = null;
    mapMergedEvent = null;
    mapSeenEvent = null;
  }
}

const HOST = process.env.HOST || "0.0.0.0";
const PORT = Number(process.env.PORT || 8088);
const DATA_ROOT = process.env.VAULT_DATA_ROOT || "/var/sods/vault";
const BLE_IDENTITY_ENABLED = process.env.BLE_IDENTITY_ENABLED !== "0";
const BLE_REGISTRY_DB = process.env.BLE_REGISTRY_DB || "/var/lib/strangelab/registry.sqlite";

let bleRegistry = null;
let bleIdentityInitError = "";

const app = express();
app.use(express.json({ limit: "2mb" }));

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function dayStamp(tsMs) {
  const d = new Date(tsMs);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function appendEvent(event) {
  const ts = Number(event?.ts_ms || Date.now());
  const day = dayStamp(ts);
  const dir = path.join(DATA_ROOT, "events", day);
  ensureDir(dir);
  const file = path.join(dir, "ingest.ndjson");
  fs.appendFileSync(file, `${JSON.stringify(event)}\n`, "utf8");
  return file;
}

function getBleRegistry() {
  if (!BLE_IDENTITY_ENABLED) return null;
  if (!BLEIdentityRegistry || !mapSeenEvent || !mapMergedEvent) return null;
  if (bleRegistry) return bleRegistry;
  if (bleIdentityInitError) return null;
  try {
    bleRegistry = new BLEIdentityRegistry({
      dbPath: BLE_REGISTRY_DB,
      logger: (line) => console.log(`[ble-identity] ${line}`),
    });
    return bleRegistry;
  } catch (error) {
    bleIdentityInitError = String(error?.message || error);
    console.error(`[ble-identity] disabled: ${bleIdentityInitError}`);
    return null;
  }
}

function isBleObservationType(type) {
  const value = String(type || "").toLowerCase();
  return value === "ble.observation"
    || value.endsWith(".ble.observation")
    || value.includes("ble.observation.");
}

function buildObservationPayload(event) {
  const data = event?.data && typeof event.data === "object" ? event.data : {};
  return {
    ts_ms: Number(event?.ts_ms || Date.now()),
    scanner_id: String(data.scanner_id || data.node_id || event?.src || "unknown"),
    addr: data.addr ?? data.address ?? data.ble_addr ?? "",
    addr_type: data.addr_type ?? data.address_type ?? "unknown",
    rssi: data.rssi ?? data.signal ?? data.dbm ?? null,
    adv_data_raw: data.adv_data_raw ?? data.adv_raw ?? "",
    scan_rsp_raw: data.scan_rsp_raw ?? data.scan_response_raw ?? "",
    name: data.name ?? "",
    services: data.services ?? [],
    mfg_company_id: data.mfg_company_id ?? data.manufacturer_company_id ?? data.company_id ?? null,
    mfg_data_raw: data.mfg_data_raw ?? data.manufacturer_data_raw ?? data.mfg_data ?? "",
    tx_power: data.tx_power ?? null,
    src: event?.src || "unknown",
    node_id: data.node_id ?? event?.src ?? "unknown",
  };
}

function deriveBleEvents(event) {
  if (!isBleObservationType(event?.type)) return [];
  const registry = getBleRegistry();
  if (!registry) return [];
  const result = registry.processObservation(buildObservationPayload(event));
  if (!result || result.ignored) return [];
  const seen = mapSeenEvent(result);
  const merged = mapMergedEvent(result, "ble-identity");
  return merged ? [seen, merged] : [seen];
}

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "vault-ingest",
    port: PORT,
    root: DATA_ROOT,
    ble_identity: {
      enabled: BLE_IDENTITY_ENABLED,
      active: Boolean(getBleRegistry()),
      db_path: BLE_REGISTRY_DB,
      init_error: bleIdentityInitError || null,
    },
  });
});

app.post("/v1/ingest", (req, res) => {
  const event = req.body;
  if (!event || typeof event !== "object") {
    return res.status(400).json({ ok: false, error: "event object required" });
  }
  const hasType = typeof event.type === "string" && event.type.length > 0;
  const hasSrc = typeof event.src === "string" && event.src.length > 0;
  const hasTs = Number.isFinite(Number(event.ts_ms));
  if (!hasType || !hasSrc || !hasTs || typeof event.data === "undefined") {
    return res.status(400).json({ ok: false, error: "missing required fields: type, src, ts_ms, data" });
  }

  try {
    const file = appendEvent(event);
    const derived = deriveBleEvents(event);
    for (const extra of derived) {
      appendEvent(extra);
    }
    return res.json({ ok: true, stored: true, file, derived_count: derived.length });
  } catch (error) {
    return res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.listen(PORT, HOST, () => {
  ensureDir(DATA_ROOT);
  console.log(`vault-ingest listening on http://${HOST}:${PORT}`);
});
