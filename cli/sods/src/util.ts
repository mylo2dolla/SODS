export function nowMs(): number {
  return Date.now();
}

export function safeJsonParse(raw: string): { ok: true; value: any } | { ok: false; error: string } {
  try {
    return { ok: true, value: JSON.parse(raw) };
  } catch (err: any) {
    return { ok: false, error: err?.message ?? "invalid_json" };
  }
}

export function asNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

export function asString(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  return undefined;
}

export function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

export function hashToHue(input: string): number {
  let hash = 2166136261;
  for (let i = 0; i < input.length; i += 1) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) % 360;
}

export function rssiToLightness(rssi: number): number {
  const clamped = clamp((rssi + 100) / 70, 0, 1);
  return 0.2 + clamped * 0.6;
}

export function stabilityToSaturation(stability: number): number {
  return clamp(0.35 + stability * 0.55, 0.2, 0.9);
}

export function recencyToLightness(ageMs: number, halfLifeMs = 4500): number {
  const decay = Math.exp(-Math.log(2) * ageMs / Math.max(1, halfLifeMs));
  const clamped = clamp(decay, 0, 1);
  return 0.18 + clamped * 0.72;
}

export function expDecay(value: number, dtMs: number, halfLifeMs: number): number {
  if (halfLifeMs <= 0) return 0;
  const decay = Math.exp(-Math.log(2) * dtMs / halfLifeMs);
  return value * decay;
}

export function isoFromMs(ms: number): string {
  return new Date(ms).toISOString();
}
