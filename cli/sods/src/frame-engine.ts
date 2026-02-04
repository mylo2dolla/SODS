import { CanonicalEvent, SignalFrame, SignalSource } from "./schema.js";
import { asNumber, asString, clamp, expDecay, hashToHue, recencyToLightness, stabilityToSaturation } from "./util.js";

type DeviceState = {
  device_id: string;
  node_id: string;
  source: SignalSource;
  channel: number;
  frequency: number;
  rssi: number;
  persistence: number;
  hitScore: number;
  lastSeen: number;
};

export class FrameEngine {
  private devices = new Map<string, DeviceState>();
  private lastTick = Date.now();

  constructor(private fps = 30, private halfLifeMs = 2600) {}

  ingest(ev: CanonicalEvent) {
    const device_id = deriveDeviceId(ev);
    if (!device_id) return;

    const source = deriveSource(ev.kind);
    const rssi = normalizeRssi(ev.data);
    const channel = deriveChannel(ev.data, source);
    const frequency = channelToFrequency(channel, source);
    const now = Date.now();
    const key = device_id;

    const existing = this.devices.get(key);
    const next: DeviceState = existing ?? {
      device_id,
      node_id: ev.node_id,
      source,
      channel,
      frequency,
      rssi,
      persistence: 0.4,
      hitScore: 0,
      lastSeen: now,
    };

    next.node_id = ev.node_id;
    next.source = source;
    next.channel = channel;
    next.frequency = frequency;
    next.rssi = rssi;
    next.hitScore = Math.min(12, next.hitScore + 1.2);
    next.persistence = Math.min(1, next.persistence + 0.22);
    next.lastSeen = now;

    this.devices.set(key, next);
  }

  tick(): SignalFrame[] {
    const now = Date.now();
    const dt = now - this.lastTick;
    this.lastTick = now;
    const frames: SignalFrame[] = [];

    for (const state of this.devices.values()) {
      state.hitScore = expDecay(state.hitScore, dt, this.halfLifeMs);
      state.persistence = expDecay(state.persistence, dt, this.halfLifeMs);
      if (now - state.lastSeen > 30_000 && state.persistence < 0.05) {
        this.devices.delete(state.device_id);
        continue;
      }
      const stability = clamp(state.hitScore / 6, 0, 1);
      const confidence = clamp(0.25 + stability * 0.75, 0.1, 1);
      const age = now - state.lastSeen;
      const glow = clamp(0.2 + stability * 0.6 + state.persistence * 0.4, 0.1, 1);
      const position = framePosition(state, stability);
      const color = {
        h: hashToHue(state.device_id),
        s: stabilityToSaturation(confidence),
        l: recencyToLightness(age),
      };
      frames.push({
        t: now,
        source: state.source,
        node_id: state.node_id,
        device_id: state.device_id,
        channel: state.channel,
        frequency: state.frequency,
        rssi: state.rssi,
        x: position.x,
        y: position.y,
        z: position.z,
        color,
        glow,
        persistence: clamp(state.persistence, 0, 1),
        velocity: stability * 0.6,
        confidence,
      });
    }
    return frames;
  }
}

function framePosition(state: DeviceState, stability: number) {
  const hue = hashToHue(state.device_id);
  const offset = (hue / 360) * Math.PI * 2;
  const maxChannel = state.source === "ble" ? 39 : state.source === "wifi" ? 165 : 13;
  const channelNorm = maxChannel > 0 ? clamp(state.channel / maxChannel, 0, 1) : 0.5;
  const angle = channelNorm * Math.PI * 2 + offset * 0.35;
  const baseRadius = state.source === "ble" ? 0.28 : state.source === "wifi" ? 0.52 : 0.7;
  const jitter = (hashToHue(state.device_id + ":r") / 360) * 0.06;
  const radius = clamp(baseRadius + jitter + state.persistence * 0.08 + stability * 0.06, 0.2, 0.95);
  const x = 0.5 + Math.cos(angle) * radius;
  const y = 0.5 + Math.sin(angle) * radius;
  const z = clamp(0.2 + state.persistence * 0.6 + stability * 0.2, 0.1, 1);
  return { x, y, z };
}

function deriveDeviceId(ev: CanonicalEvent): string | null {
  const data = ev.data ?? {};
  const candidates = [
    "device_id",
    "deviceId",
    "device",
    "addr",
    "address",
    "mac",
    "mac_address",
    "bssid",
    "ble_addr",
  ];
  for (const key of candidates) {
    const v = asString((data as any)[key]);
    if (v && v.trim().length > 0) {
      if (ev.kind.includes("ble") && !v.startsWith("ble:")) return `ble:${v}`;
      return v;
    }
  }
  if (ev.node_id && ev.node_id !== "unknown") return `node:${ev.node_id}`;
  return null;
}

function deriveSource(kind: string): SignalSource {
  if (kind.includes("ble")) return "ble";
  if (kind.includes("wifi")) return "wifi";
  return "esp";
}

function normalizeRssi(data: Record<string, unknown>): number {
  const keys = ["rssi", "RSSI", "signal", "strength", "dbm", "level"];
  for (const key of keys) {
    const n = asNumber((data as any)[key], NaN);
    if (Number.isFinite(n)) return n;
  }
  return -60;
}

function deriveChannel(data: Record<string, unknown>, source: SignalSource): number {
  const raw = asNumber((data as any)["channel"], NaN);
  if (Number.isFinite(raw)) return raw;
  if (source === "ble") return 37;
  return 1;
}

function channelToFrequency(channel: number, source: SignalSource): number {
  if (source === "ble") {
    if (channel === 37) return 2402;
    if (channel === 38) return 2426;
    if (channel === 39) return 2480;
    return 2402;
  }
  if (channel >= 1 && channel <= 14) {
    return 2412 + (channel - 1) * 5;
  }
  if (channel >= 36 && channel <= 165) {
    return 5000 + channel * 5;
  }
  return 2400 + channel * 5;
}
