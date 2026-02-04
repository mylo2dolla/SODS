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
  recv_ts?: string;
  event_ts?: string;
  node_id?: string;
  kind?: string;
  severity?: string;
  summary?: string;
  data_json?: any;
};

export class Ingestor {
  private baseURL: string;
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

  constructor(baseURL: string, limit = 500, pollIntervalMs = 1400) {
    this.baseURL = baseURL.replace(/\/+$/, "");
    this.limit = limit;
    this.pollIntervalMs = pollIntervalMs;
  }

  start(onEvent: (ev: CanonicalEvent) => void, onError: (msg: string) => void) {
    this.onEvent = onEvent;
    this.onError = onError;
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
    try {
      const url = new URL(`${this.baseURL}/v1/events`);
      url.searchParams.set("limit", String(this.limit));
      const res = await fetch(url, { method: "GET", headers: { "Accept": "application/json" } });
      if (!res.ok) {
        this.onError?.(`pi-logger HTTP ${res.status}`);
        return;
      }
      const body = await res.json();
      const items: RawEvent[] = Array.isArray(body) ? body : body.items ?? body.events ?? [];
      this.counters.events_in += items.length;

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
    } catch (err: any) {
      this.onError?.(err?.message ?? "pi-logger fetch failed");
    }
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
    const recvMs = parseIsoToMs(raw.recv_ts) ?? nowMs();
    const eventMs = parseIsoToMs(raw.event_ts) ?? recvMs;
    const node_id = (raw.node_id ?? "unknown").trim() || "unknown";
    const kind = (raw.kind ?? "unknown").trim() || "unknown";
    const severity = (raw.severity ?? "info").trim() || "info";
    const summary = (raw.summary ?? kind).trim() || kind;
    const data = this.parseDataJson(raw.data_json);

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
