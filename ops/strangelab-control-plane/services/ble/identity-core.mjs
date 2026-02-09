import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { dirname } from "node:path";
import { existsSync, mkdirSync } from "node:fs";

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const DEFAULT_DB_PATH = process.env.BLE_REGISTRY_DB || "/var/lib/strangelab/registry.sqlite";
const DEFAULT_SQLITE_BIN = process.env.SQLITE_BIN || "sqlite3";

const MFG_MASK_RULES = {
  "004c": [true, true, true, true, true, true, false, false, false, false, false, false, false, false, false, false],
  "0006": [true, true, true, true, false, false, false, false, false, false, false, false],
};

function sha256(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function toBase32Hex(hex) {
  const bytes = Buffer.from(hex, "hex");
  let output = "";
  let bits = 0;
  let buffer = 0;
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      output += BASE32_ALPHABET[(buffer >> bits) & 31];
    }
  }
  if (bits > 0) {
    output += BASE32_ALPHABET[(buffer << (5 - bits)) & 31];
  }
  return output;
}

function sqlQuote(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function parseHexBytes(raw) {
  if (!raw || typeof raw !== "string") return [];
  const cleaned = raw.replace(/[^a-fA-F0-9]/g, "").toLowerCase();
  if (cleaned.length < 2) return [];
  const out = [];
  for (let i = 0; i + 1 < cleaned.length; i += 2) {
    out.push(parseInt(cleaned.slice(i, i + 2), 16));
  }
  return out;
}

function bytesToHex(bytes) {
  return bytes.map((b) => b.toString(16).padStart(2, "0")).join("");
}

function normalizeServices(services) {
  if (!Array.isArray(services)) return [];
  return Array.from(new Set(
    services
      .map((s) => String(s || "").trim().toLowerCase())
      .filter(Boolean)
  )).sort();
}

export function normalizeName(rawName) {
  if (rawName === null || rawName === undefined) return "";
  let name = String(rawName).trim().toLowerCase();
  name = name.replace(/\s+/g, " ");
  name = name.replace(/(?:[_-]?[a-f0-9]{4,}|\s+[a-f0-9]{4,}|\s*\(\d+\))$/gi, "").trim();
  return name;
}

export function maskManufacturer(companyId, mfgRawHex) {
  const bytes = parseHexBytes(mfgRawHex);
  if (bytes.length === 0) {
    return { mfg_mask: [], mfg_masked: "", mfg_data_raw: "" };
  }
  const companyKey = companyId === null || companyId === undefined
    ? ""
    : Number(companyId).toString(16).padStart(4, "0").toLowerCase();

  let mask = MFG_MASK_RULES[companyKey];
  if (!mask) {
    const keepCount = Math.min(4, bytes.length);
    mask = bytes.map((_, idx) => idx < keepCount);
  }
  if (mask.length < bytes.length) {
    mask = [...mask, ...new Array(bytes.length - mask.length).fill(false)];
  }
  const maskedBytes = bytes.map((byte, idx) => (mask[idx] ? byte : 0));

  return {
    mfg_mask: mask,
    mfg_masked: bytesToHex(maskedBytes),
    mfg_data_raw: bytesToHex(bytes),
  };
}

export function computeFingerprints(observation) {
  const servicesNorm = normalizeServices(observation.services);
  const company = observation.mfg_company_id === null || observation.mfg_company_id === undefined
    ? ""
    : String(Number(observation.mfg_company_id));
  const nameNorm = normalizeName(observation.name);
  const masked = maskManufacturer(observation.mfg_company_id, observation.mfg_data_raw);

  const stableInput = [
    servicesNorm.join(","),
    company,
    masked.mfg_masked,
    nameNorm,
  ].join("|");

  const hasStableMaterial = Boolean(servicesNorm.length || company || masked.mfg_masked || nameNorm);
  const fpStable = hasStableMaterial ? sha256(stableInput) : null;
  const fpAddr = sha256(`${String(observation.addr || "").toLowerCase()}/${String(observation.addr_type || "unknown").toLowerCase()}`);

  return {
    fp_stable: fpStable,
    fp_addr: fpAddr,
    services_norm: servicesNorm,
    name_norm: nameNorm,
    ...masked,
  };
}

function normalizeObservation(raw) {
  const tsMs = Number(raw.ts_ms || Date.now());
  const services = Array.isArray(raw.services)
    ? raw.services
    : String(raw.services || "").split(",").map((s) => s.trim()).filter(Boolean);

  const companyRaw = raw.mfg_company_id ?? raw.manufacturer_company_id ?? raw.company_id;
  let company = null;
  if (companyRaw !== null && companyRaw !== undefined && String(companyRaw).trim() !== "") {
    const text = String(companyRaw).trim();
    company = text.startsWith("0x") ? Number.parseInt(text.slice(2), 16) : Number.parseInt(text, 10);
    if (Number.isNaN(company)) company = null;
  }

  return {
    ts_ms: Number.isFinite(tsMs) ? tsMs : Date.now(),
    scanner_id: String(raw.scanner_id || raw.src || raw.node_id || "unknown"),
    rssi: Number(raw.rssi ?? raw.signal ?? raw.dbm ?? NaN),
    addr: String(raw.addr || raw.address || raw.ble_addr || "").trim().toLowerCase(),
    addr_type: String(raw.addr_type || raw.address_type || "unknown").trim().toLowerCase(),
    adv_data_raw: String(raw.adv_data_raw || raw.adv_raw || ""),
    scan_rsp_raw: String(raw.scan_rsp_raw || raw.scan_response_raw || ""),
    name: raw.name ? String(raw.name) : "",
    services,
    mfg_company_id: company,
    mfg_data_raw: String(raw.mfg_data_raw || raw.manufacturer_data_raw || raw.mfg_data || ""),
    tx_power: raw.tx_power === undefined ? null : Number(raw.tx_power),
  };
}

function overlapRatio(a, b) {
  if (!a.length || !b.length) return 0;
  const setA = new Set(a);
  const setB = new Set(b);
  let overlap = 0;
  for (const value of setA) {
    if (setB.has(value)) overlap += 1;
  }
  return overlap / Math.max(setA.size, setB.size);
}

function isPublicAddr(addrType) {
  const normalized = String(addrType || "").toLowerCase();
  return normalized === "public" || normalized === "public_device";
}

function emptyMeta() {
  return {
    candidate: false,
    scanners: [],
    services: [],
    name_norm: "",
    company_id: null,
    mfg_masked: "",
    addr_set: [],
    addr_public_set: [],
    last_addr: "",
    last_addr_type: "",
    confidence: 0,
    fp_stable: null,
    fp_addr: null,
  };
}

export class BLEIdentityRegistry {
  constructor({ dbPath = DEFAULT_DB_PATH, sqliteBin = DEFAULT_SQLITE_BIN, logger = () => {}, reset = false } = {}) {
    this.dbPath = dbPath;
    this.sqliteBin = sqliteBin;
    this.logger = logger;

    this.devices = new Map();
    this.fpMap = new Map();
    this.companyIndex = new Map();
    this.recentSignalMap = new Map();

    this.ensureDbPath();
    this.initDb();
    if (reset) {
      this.clearAll();
    }
    this.loadCache();
  }

  ensureDbPath() {
    const dir = dirname(this.dbPath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }

  runSql(sql) {
    return execFileSync(this.sqliteBin, [this.dbPath, sql], { encoding: "utf8" });
  }

  queryJson(sql) {
    const out = execFileSync(this.sqliteBin, ["-json", this.dbPath, sql], { encoding: "utf8" }).trim();
    if (!out) return [];
    return JSON.parse(out);
  }

  initDb() {
    this.runSql(`
      PRAGMA journal_mode=WAL;
      CREATE TABLE IF NOT EXISTS ble_devices (
        device_id TEXT PRIMARY KEY,
        primary_fp TEXT,
        created_ts INTEGER,
        last_seen_ts INTEGER,
        meta_json TEXT
      );
      CREATE TABLE IF NOT EXISTS ble_fps (
        fp TEXT PRIMARY KEY,
        device_id TEXT,
        kind TEXT,
        created_ts INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_ble_fps_device_id ON ble_fps(device_id);
      CREATE TABLE IF NOT EXISTS ble_aliases (
        device_id TEXT,
        addr_last TEXT,
        name_last TEXT,
        company_id_last TEXT,
        updated_ts INTEGER,
        PRIMARY KEY(device_id)
      );
      CREATE INDEX IF NOT EXISTS idx_ble_aliases_addr ON ble_aliases(addr_last);
    `);
  }

  clearAll() {
    this.runSql(`
      DELETE FROM ble_fps;
      DELETE FROM ble_aliases;
      DELETE FROM ble_devices;
      VACUUM;
    `);
    this.devices.clear();
    this.fpMap.clear();
    this.companyIndex.clear();
    this.recentSignalMap.clear();
  }

  loadCache() {
    this.devices.clear();
    this.fpMap.clear();
    this.companyIndex.clear();

    const deviceRows = this.queryJson("SELECT device_id, primary_fp, created_ts, last_seen_ts, meta_json FROM ble_devices");
    for (const row of deviceRows) {
      let meta = emptyMeta();
      try {
        if (row.meta_json) {
          meta = { ...meta, ...JSON.parse(row.meta_json) };
        }
      } catch {
        meta = emptyMeta();
      }
      const device = {
        device_id: String(row.device_id),
        primary_fp: row.primary_fp ? String(row.primary_fp) : null,
        created_ts: Number(row.created_ts || Date.now()),
        last_seen_ts: Number(row.last_seen_ts || Date.now()),
        meta,
        fps: new Set(),
      };
      this.devices.set(device.device_id, device);
      if (meta.company_id !== null && meta.company_id !== undefined) {
        const key = String(meta.company_id);
        if (!this.companyIndex.has(key)) this.companyIndex.set(key, new Set());
        this.companyIndex.get(key).add(device.device_id);
      }
    }

    const fpRows = this.queryJson("SELECT fp, device_id, kind FROM ble_fps");
    for (const row of fpRows) {
      const fp = String(row.fp || "");
      const deviceId = String(row.device_id || "");
      if (!fp || !deviceId) continue;
      this.fpMap.set(fp, deviceId);
      const device = this.devices.get(deviceId);
      if (device) {
        device.fps.add(fp);
      }
    }
  }

  buildDeviceId(primaryFingerprint) {
    const digest = sha256(primaryFingerprint);
    return `ble:${toBase32Hex(digest).slice(0, 26).toLowerCase()}`;
  }

  scoreCandidate(candidate, obs, fp) {
    let score = 0;

    if (fp.fp_stable && candidate.fps.has(fp.fp_stable)) score += 60;

    const candidateServices = Array.isArray(candidate.meta.services) ? candidate.meta.services : [];
    const overlap = overlapRatio(candidateServices, fp.services_norm);
    if (overlap >= 0.5) score += 25;

    const candidateCompany = candidate.meta.company_id;
    if (candidateCompany !== null && obs.mfg_company_id !== null) {
      if (Number(candidateCompany) === Number(obs.mfg_company_id)) {
        if (candidate.meta.mfg_masked && fp.mfg_masked && candidate.meta.mfg_masked === fp.mfg_masked) {
          score += 20;
        }
      } else {
        score -= 30;
      }
    }

    if (candidate.meta.name_norm && fp.name_norm && candidate.meta.name_norm === fp.name_norm) {
      score += 10;
    }

    if (isPublicAddr(obs.addr_type) && Array.isArray(candidate.meta.addr_public_set) && candidate.meta.addr_public_set.includes(obs.addr)) {
      score += 10;
    }

    if (candidateServices.length > 0 && fp.services_norm.length > 0 && overlap === 0) {
      score -= 40;
    }

    return score;
  }

  pickCandidate(obs, fp) {
    const candidateIDs = new Set();
    if (fp.fp_stable && this.fpMap.has(fp.fp_stable)) candidateIDs.add(this.fpMap.get(fp.fp_stable));
    if (fp.fp_addr && this.fpMap.has(fp.fp_addr)) candidateIDs.add(this.fpMap.get(fp.fp_addr));
    if (obs.mfg_company_id !== null) {
      const byCompany = this.companyIndex.get(String(obs.mfg_company_id));
      if (byCompany) {
        for (const id of byCompany) candidateIDs.add(id);
      }
    }

    let best = null;
    let bestScore = -Infinity;

    for (const id of candidateIDs) {
      const candidate = this.devices.get(id);
      if (!candidate) continue;
      const score = this.scoreCandidate(candidate, obs, fp);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    return { best, bestScore };
  }

  upsertDevice(device) {
    const metaJson = JSON.stringify(device.meta);
    this.runSql(`
      INSERT INTO ble_devices(device_id, primary_fp, created_ts, last_seen_ts, meta_json)
      VALUES(${sqlQuote(device.device_id)}, ${sqlQuote(device.primary_fp)}, ${Number(device.created_ts)}, ${Number(device.last_seen_ts)}, ${sqlQuote(metaJson)})
      ON CONFLICT(device_id) DO UPDATE SET
        primary_fp=excluded.primary_fp,
        last_seen_ts=excluded.last_seen_ts,
        meta_json=excluded.meta_json;
    `);

    this.runSql(`
      INSERT INTO ble_aliases(device_id, addr_last, name_last, company_id_last, updated_ts)
      VALUES(
        ${sqlQuote(device.device_id)},
        ${sqlQuote(device.meta.last_addr || "")},
        ${sqlQuote(device.meta.name_norm || "")},
        ${sqlQuote(device.meta.company_id === null || device.meta.company_id === undefined ? "" : String(device.meta.company_id))},
        ${Date.now()}
      )
      ON CONFLICT(device_id) DO UPDATE SET
        addr_last=excluded.addr_last,
        name_last=excluded.name_last,
        company_id_last=excluded.company_id_last,
        updated_ts=excluded.updated_ts;
    `);
  }

  linkFingerprint(deviceId, fp, kind, tsMs) {
    if (!fp) return;
    this.fpMap.set(fp, deviceId);
    const device = this.devices.get(deviceId);
    if (device) device.fps.add(fp);
    this.runSql(`
      INSERT INTO ble_fps(fp, device_id, kind, created_ts)
      VALUES(${sqlQuote(fp)}, ${sqlQuote(deviceId)}, ${sqlQuote(kind)}, ${Number(tsMs)})
      ON CONFLICT(fp) DO UPDATE SET
        device_id=excluded.device_id,
        kind=excluded.kind;
    `);
  }

  mergeDevices(fromDeviceId, toDeviceId, reason) {
    if (!fromDeviceId || !toDeviceId || fromDeviceId === toDeviceId) return null;
    const fromDevice = this.devices.get(fromDeviceId);
    const toDevice = this.devices.get(toDeviceId);
    if (!fromDevice || !toDevice) return null;

    const winner = fromDevice.created_ts <= toDevice.created_ts ? fromDevice : toDevice;
    const loser = winner.device_id === fromDevice.device_id ? toDevice : fromDevice;

    for (const fp of loser.fps) {
      this.fpMap.set(fp, winner.device_id);
      winner.fps.add(fp);
      this.runSql(`UPDATE ble_fps SET device_id=${sqlQuote(winner.device_id)} WHERE fp=${sqlQuote(fp)};`);
    }

    const winnerServices = new Set(winner.meta.services || []);
    for (const svc of loser.meta.services || []) winnerServices.add(svc);
    winner.meta.services = Array.from(winnerServices).sort();
    winner.meta.candidate = winner.meta.candidate && loser.meta.candidate;
    winner.meta.addr_set = Array.from(new Set([...(winner.meta.addr_set || []), ...(loser.meta.addr_set || [])]));
    winner.meta.addr_public_set = Array.from(new Set([...(winner.meta.addr_public_set || []), ...(loser.meta.addr_public_set || [])]));
    winner.meta.scanners = Array.from(new Set([...(winner.meta.scanners || []), ...(loser.meta.scanners || [])]));
    winner.last_seen_ts = Math.max(Number(winner.last_seen_ts || 0), Number(loser.last_seen_ts || 0));

    this.upsertDevice(winner);
    this.runSql(`DELETE FROM ble_aliases WHERE device_id=${sqlQuote(loser.device_id)};`);
    this.runSql(`DELETE FROM ble_devices WHERE device_id=${sqlQuote(loser.device_id)};`);

    this.devices.delete(loser.device_id);

    return {
      from_device_id: loser.device_id,
      to_device_id: winner.device_id,
      reason,
    };
  }

  processObservation(rawObservation) {
    const obs = normalizeObservation(rawObservation);
    if (!obs.addr) {
      return { ignored: true, reason: "missing address" };
    }

    const fp = computeFingerprints(obs);
    const primaryFingerprint = fp.fp_stable || fp.fp_addr;
    const derivedDeviceId = this.buildDeviceId(primaryFingerprint);

    const { best, bestScore } = this.pickCandidate(obs, fp);

    let targetDevice = null;
    let confidence = 0;
    let candidateMode = false;

    if (best && bestScore >= 70) {
      targetDevice = best;
      confidence = clamp(bestScore, 0, 100);
    } else if (best && bestScore >= 50) {
      targetDevice = best;
      confidence = clamp(bestScore, 0, 100);
      candidateMode = true;
    } else {
      targetDevice = this.devices.get(derivedDeviceId) || {
        device_id: derivedDeviceId,
        primary_fp: primaryFingerprint,
        created_ts: obs.ts_ms,
        last_seen_ts: obs.ts_ms,
        meta: emptyMeta(),
        fps: new Set(),
      };
      confidence = fp.fp_stable ? 62 : 35;
      candidateMode = true;
    }

    targetDevice.primary_fp = targetDevice.primary_fp || primaryFingerprint;
    targetDevice.last_seen_ts = Math.max(Number(targetDevice.last_seen_ts || 0), obs.ts_ms);

    const meta = targetDevice.meta || emptyMeta();
    meta.candidate = candidateMode;
    meta.scanners = Array.from(new Set([...(meta.scanners || []), obs.scanner_id]));
    meta.services = Array.from(new Set([...(meta.services || []), ...fp.services_norm])).sort();
    meta.name_norm = fp.name_norm || meta.name_norm || "";
    meta.company_id = obs.mfg_company_id === null ? meta.company_id ?? null : obs.mfg_company_id;
    meta.mfg_masked = fp.mfg_masked || meta.mfg_masked || "";
    meta.addr_set = Array.from(new Set([...(meta.addr_set || []), obs.addr]));
    if (isPublicAddr(obs.addr_type)) {
      meta.addr_public_set = Array.from(new Set([...(meta.addr_public_set || []), obs.addr]));
    }
    meta.last_addr = obs.addr;
    meta.last_addr_type = obs.addr_type;
    meta.confidence = Math.round(confidence);
    meta.fp_stable = fp.fp_stable;
    meta.fp_addr = fp.fp_addr;
    targetDevice.meta = meta;

    this.devices.set(targetDevice.device_id, targetDevice);

    if (meta.company_id !== null && meta.company_id !== undefined) {
      const key = String(meta.company_id);
      if (!this.companyIndex.has(key)) this.companyIndex.set(key, new Set());
      this.companyIndex.get(key).add(targetDevice.device_id);
    }

    this.upsertDevice(targetDevice);
    if (fp.fp_stable) this.linkFingerprint(targetDevice.device_id, fp.fp_stable, "stable", obs.ts_ms);
    if (fp.fp_addr) this.linkFingerprint(targetDevice.device_id, fp.fp_addr, "addr", obs.ts_ms);

    let merged = null;
    const mergeKeys = [];
    if (fp.fp_stable) mergeKeys.push(`stable:${fp.fp_stable}`);
    if (meta.company_id !== null && fp.mfg_masked) mergeKeys.push(`mfg:${meta.company_id}:${fp.mfg_masked}`);

    for (const mergeKey of mergeKeys) {
      const prior = this.recentSignalMap.get(mergeKey);
      if (prior && obs.ts_ms - prior.ts_ms <= 5_000 && prior.device_id !== targetDevice.device_id) {
        merged = this.mergeDevices(prior.device_id, targetDevice.device_id, `merge-window:${mergeKey}`);
        if (merged) {
          targetDevice = this.devices.get(merged.to_device_id) || targetDevice;
        }
      }
      this.recentSignalMap.set(mergeKey, {
        ts_ms: obs.ts_ms,
        scanner_id: obs.scanner_id,
        device_id: targetDevice.device_id,
      });
    }

    const result = {
      ok: true,
      observation: obs,
      device_id: targetDevice.device_id,
      confidence: Math.round(confidence),
      score: bestScore === -Infinity ? null : bestScore,
      candidate: candidateMode,
      fingerprints: {
        fp_stable: fp.fp_stable,
        fp_addr: fp.fp_addr,
        primary_fp: primaryFingerprint,
      },
      merged,
      meta: targetDevice.meta,
    };

    this.logger(`ble.identity device=${result.device_id} confidence=${result.confidence} candidate=${result.candidate}`);
    return result;
  }
}

export function mapSeenEvent(result) {
  const obs = result.observation;
  return {
    type: "ble.device.seen",
    src: obs.scanner_id,
    ts_ms: obs.ts_ms,
    data: {
      node_id: obs.scanner_id,
      device_id: result.device_id,
      scanner_id: obs.scanner_id,
      rssi: Number.isFinite(obs.rssi) ? obs.rssi : null,
      addr: obs.addr,
      addr_type: obs.addr_type,
      name_norm: result.meta.name_norm || "",
      services: result.meta.services || [],
      company_id: result.meta.company_id,
      confidence: result.confidence,
      candidate: result.candidate,
      fp_stable: result.fingerprints.fp_stable,
      fp_addr: result.fingerprints.fp_addr,
    },
  };
}

export function mapMergedEvent(result, sourceNodeId = "ble-identity") {
  if (!result.merged) return null;
  return {
    type: "ble.device.merged",
    src: sourceNodeId,
    ts_ms: Date.now(),
    data: {
      node_id: sourceNodeId,
      device_id: result.merged.to_device_id,
      from_device_id: result.merged.from_device_id,
      to_device_id: result.merged.to_device_id,
      reason: result.merged.reason,
    },
  };
}
