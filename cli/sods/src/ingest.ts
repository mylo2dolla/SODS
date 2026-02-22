import { CanonicalEvent, NodeSnapshot } from "./schema.js";
import { asNumber, asString, isoFromMs, nowMs, safeJsonParse } from "./util.js";

export type IngestCounters = {
  events_in: number;
  events_bad_json: number;
  events_out: number;
  nodes_seen: number;
};

type RawEvent = {
  id?: string | number;
  ts_ms?: number | string;
  type?: string;
  src?: string;
  data?: any;
  recv_ts?: string;
  event_ts?: string;
  node_id?: string;
  kind?: string;
  severity?: string;
  summary?: string;
  data_json?: any;
};

const DEFAULT_AUX_HOST = process.env.SODS_DEFAULT_AUX_HOST || "192.168.8.114";

function resolveAuxHost(): string {
  const candidate = process.env.AUX_HOST || process.env.SODS_AUX_HOST || DEFAULT_AUX_HOST;
  const trimmed = String(candidate || "").trim();
  return trimmed.length > 0 ? trimmed : DEFAULT_AUX_HOST;
}

export class Ingestor {
  private baseURLs: string[];
  private activeBaseURL: string;
  private pollIntervalMs: number;
  private limit: number;
  private timer?: NodeJS.Timeout;
  private lastSeenNumericId = -1;
  private seenIds: string[] = [];
  private seenSet: Set<string> = new Set();
  private seenMax = 2000;
  private nodeMap = new Map<string, NodeSnapshot>();
  private lastIngestAt = 0;
  private counters: IngestCounters = {
    events_in: 0,
    events_bad_json: 0,
    events_out: 0,
    nodes_seen: 0,
  };
  private onEvent?: (ev: CanonicalEvent) => void;
  private onError?: (msg: string) => void;
  private onPollSuccess?: () => void;
  private eventsPathByBase = new Map<string, string>();

  constructor(baseURL: string, limit = 500, pollIntervalMs = 1400) {
    this.baseURLs = buildBaseURLList(baseURL);
    const auxHost = resolveAuxHost();
    this.activeBaseURL = this.baseURLs[0] ?? `http://${auxHost}:9101`;
    this.limit = limit;
    this.pollIntervalMs = pollIntervalMs;
  }

  getActiveBaseURL() {
    return this.activeBaseURL;
  }

  getBaseURLs() {
    return [...this.baseURLs];
  }

  start(onEvent: (ev: CanonicalEvent) => void, onError: (msg: string) => void, onPollSuccess?: () => void) {
    this.onEvent = onEvent;
    this.onError = onError;
    this.onPollSuccess = onPollSuccess;
    this.stop();
    this.timer = setInterval(() => this.pollOnce(), this.pollIntervalMs);
    void this.pollOnce();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  getLastIngestAt() {
    return this.lastIngestAt;
  }

  getCounters(): IngestCounters {
    return { ...this.counters };
  }

  getNodes(): NodeSnapshot[] {
    return Array.from(this.nodeMap.values()).sort((a, b) => b.last_seen - a.last_seen);
  }

  private async pollOnce() {
    const ordered = [this.activeBaseURL, ...this.baseURLs.filter((u) => u !== this.activeBaseURL)];
    let lastError = "pi-logger fetch failed";

    for (const baseURL of ordered) {
      try {
        const body = await this.fetchEventsBody(baseURL);
        const items: RawEvent[] = Array.isArray(body) ? body : body.items ?? body.events ?? [];
        this.counters.events_in += items.length;
        this.activeBaseURL = baseURL;
        this.onPollSuccess?.();

        const fresh = this.filterFresh(items);
        if (fresh.length === 0) {
          this.lastIngestAt = nowMs();
          return;
        }

        for (const raw of fresh) {
          const canonical = this.toCanonical(raw);
          this.updateNodes(canonical);
          this.onEvent?.(canonical);
          this.counters.events_out++;
        }
        this.lastIngestAt = nowMs();
        return;
      } catch (err: any) {
        lastError = `${baseURL} ${err?.message ?? "fetch failed"}`;
      }
    }

    this.onError?.(lastError);
  }

  private async fetchEventsBody(baseURL: string): Promise<any> {
    const preferred = this.eventsPathByBase.get(baseURL);
    const candidatePaths = preferred
      ? [preferred, "/v1/events", "/events"].filter((v, idx, arr) => arr.indexOf(v) === idx)
      : ["/v1/events", "/events"];

    let lastErr = "events endpoint unavailable";
    for (const endpoint of candidatePaths) {
      const url = new URL(`${baseURL}${endpoint}`);
      url.searchParams.set("limit", String(this.limit));
      const res = await fetch(url, { method: "GET", headers: { "Accept": "application/json" } });
      if (!res.ok) {
        lastErr = `${baseURL}${endpoint} HTTP ${res.status}`;
        continue;
      }
      this.eventsPathByBase.set(baseURL, endpoint);
      return await res.json();
    }
    throw new Error(lastErr);
  }

  private filterFresh(items: RawEvent[]): RawEvent[] {
    const out: RawEvent[] = [];
    for (const raw of items) {
      const id = raw.id;
      if (typeof id === "number") {
        if (id > this.lastSeenNumericId) {
          out.push(raw);
          this.lastSeenNumericId = Math.max(this.lastSeenNumericId, id);
        }
        continue;
      }
      const strId = id != null ? String(id) : "";
      if (strId) {
        if (this.seenSet.has(strId)) continue;
        this.trackSeen(strId);
        out.push(raw);
        continue;
      }
      out.push(raw);
    }
    return out;
  }

  private trackSeen(id: string) {
    this.seenSet.add(id);
    this.seenIds.push(id);
    if (this.seenIds.length > this.seenMax) {
      const drop = this.seenIds.splice(0, this.seenIds.length - this.seenMax);
      for (const d of drop) this.seenSet.delete(d);
    }
  }

  private toCanonical(raw: RawEvent): CanonicalEvent {
    const parsedTsMs = asNumber(raw.ts_ms);
    const recvMs = parseIsoToMs(raw.recv_ts) ?? parsedTsMs ?? nowMs();
    const eventMs = parseIsoToMs(raw.event_ts) ?? parsedTsMs ?? recvMs;
    const node_id = (raw.node_id ?? raw.src ?? "unknown").trim() || "unknown";
    const kind = (raw.kind ?? raw.type ?? "unknown").trim() || "unknown";
    const severity = (raw.severity ?? "info").trim() || "info";
    const summary = (raw.summary ?? kind).trim() || kind;
    const data = this.parseDataJson(raw.data_json ?? raw.data);

    return {
      id: raw.id != null ? String(raw.id) : undefined,
      recv_ts: recvMs,
      event_ts: isoFromMs(eventMs),
      node_id,
      kind,
      severity,
      summary,
      data,
    };
  }

  private parseDataJson(raw: any): Record<string, unknown> {
    if (raw == null) return {};
    if (typeof raw === "object" && !Array.isArray(raw)) return raw as Record<string, unknown>;
    if (typeof raw === "string") {
      const parsed = safeJsonParse(raw);
      if (parsed.ok && typeof parsed.value === "object" && parsed.value) {
        return parsed.value as Record<string, unknown>;
      }
      this.counters.events_bad_json++;
      const err = parsed.ok ? "invalid_object" : parsed.error;
      this.onError?.(`data_json parse error: ${err}`);
      this.emitError("data_json_parse_error", { err, raw });
      return {};
    }
    return {};
  }

  private updateNodes(ev: CanonicalEvent) {
    const nodeId = ev.node_id;
    const lastSeen = Date.parse(ev.event_ts) || ev.recv_ts;
    const existing = this.nodeMap.get(nodeId);
    const data = ev.data ?? {};
    const ip = pickString(data, ["ip", "ip_addr", "ip_address"]);
    const mac = pickString(data, ["mac", "mac_address", "bssid"]);
    const hostname = pickString(data, ["hostname", "host", "name"]);
    const confidence = computeConfidence(ev.kind, lastSeen);
    const next: NodeSnapshot = {
      node_id: nodeId,
      ip: ip ?? existing?.ip,
      mac: mac ?? existing?.mac,
      hostname: hostname ?? existing?.hostname,
      last_seen: Math.max(existing?.last_seen ?? 0, lastSeen),
      last_kind: ev.kind,
      confidence: Math.max(existing?.confidence ?? 0, confidence),
    };
    this.nodeMap.set(nodeId, next);
    this.counters.nodes_seen = this.nodeMap.size;
  }

  private emitError(kind: string, data: Record<string, unknown>) {
    const now = nowMs();
    const ev: CanonicalEvent = {
      recv_ts: now,
      event_ts: isoFromMs(now),
      node_id: "sods",
      kind: `sods.${kind}`,
      severity: "warn",
      summary: "sods error",
      data,
    };
    this.onEvent?.(ev);
    this.counters.events_out++;
  }
}

function buildBaseURLList(value: string): string[] {
  // IMPORTANT: Keep the pi-logger events feed separate from Vault ingest.
  // Vault ingest (e.g. :8088/v1/ingest) is authoritative append-only storage, not an events API.
  const envList = process.env.PI_LOGGER_URL || process.env.PI_LOGGER || "";
  const auxHost = resolveAuxHost();
  // Only include event-feed sources by default. Vault ingest (:8088) is not an events API and causes noisy 404s.
  const explicit = [value, envList]
    .join(",")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const raw = explicit.length > 0 ? explicit : [`http://${auxHost}:9101`];

  const normalized = raw
    .map((s) => s.replace(/\/+$/, ""))
    .filter((s) => /^https?:\/\/[^/]+/i.test(s));

  const out: string[] = [];
  const seen = new Set<string>();
  for (const entry of normalized) {
    const key = entry.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(entry);
  }
  return out;
}

function parseIsoToMs(value?: string): number | null {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function pickString(data: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const v = data[key];
    const s = asString(v);
    if (s && s.trim().length > 0) return s.trim();
  }
  return undefined;
}

function computeConfidence(kind: string, lastSeenMs: number): number {
  const base =
    kind.includes("announce") ? 0.9 :
    kind.includes("wifi") ? 0.7 :
    kind.includes("heartbeat") ? 0.5 :
    0.4;
  const age = nowMs() - lastSeenMs;
  const decay = Math.exp(-age / 120_000);
  return Math.max(0.1, Math.min(1, base * decay));
}
