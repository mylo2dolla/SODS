# Spectrum Frame Spec (SODS)

This spec defines the single, shared **Spectrum Frame** format used by Station, Dev Station, and Ops Portal.
It represents **abstract signal presence** (not physical space) in a 4D field: identity, intensity, confidence, and time/recency.

## Frame Envelope

WS `/ws/frames` emits:

```json
{ "t": 1710000000000, "frames": [ ... ] }
```

## Frame Object

```json
{
  "t": 1710000000000,
  "source": "ble|wifi|esp",
  "node_id": "node-01",
  "device_id": "ble:aa:bb:cc:dd:ee:ff",
  "channel": 37,
  "frequency": 2402,
  "rssi": -64,
  "x": 0.62,
  "y": 0.41,
  "z": 0.72,
  "color": { "h": 140, "s": 0.7, "l": 0.65 },
  "glow": 0.8,
  "persistence": 0.6,
  "velocity": 0.4,
  "confidence": 0.8
}
```

### Field semantics

- **x/y/z**: normalized field position. `x/y` in `[0..1]`, `z` in `[0..1]`.
- **color**: stable hue by device identity; saturation = confidence; lightness = recency.
- **glow**: recency * confidence (halo intensity).
- **persistence**: memory of activity over recent frames.
- **velocity**: optional motion hint for subtle drift.

### Mapping rules (shared)

- Identity → `device_id` (or `node_id` fallback).
- Hue: stable hash of `device_id` (FNV‑1a).
- Brightness: recency decay.
- Saturation: confidence.

### Required behavior

- If frames are not available, renderers fall back to raw events and show an **idle state** rather than a blank view.
- Tool outputs and scan results should emit synthetic **tool events** that feed the same frame engine.

