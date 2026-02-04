export type SignalSource = "ble" | "wifi" | "esp";

export type CanonicalEvent = {
  id?: string;
  recv_ts: number;
  event_ts: string;
  node_id: string;
  kind: string;
  severity: string;
  summary: string;
  data: Record<string, unknown>;
};

export type SignalFrame = {
  t: number;
  source: SignalSource;
  node_id: string;
  device_id: string;
  channel: number;
  frequency: number;
  rssi: number;
  color: { h: number; s: number; l: number };
  persistence: number;
  velocity?: number;
  confidence: number;
};

export type NodeSnapshot = {
  node_id: string;
  ip?: string;
  mac?: string;
  hostname?: string;
  last_seen: number;
  last_kind?: string;
  confidence: number;
};
