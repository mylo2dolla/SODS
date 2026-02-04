# SODS Architecture

## Tiers

- **Tier 0: Dev Station (macOS)**
  - Primary operator UI.
  - Consumes SODS spine endpoints and local tooling.

- **Tier 1: Pi Aux + Logger**
  - Source of truth for events: `GET /v1/events?node_id=<id>&limit=N`.
  - SODS spine polls and normalizes this feed.

- **Tier 2: Node Agents (ESP32 / ESP32-C3)**
  - Emit `node.announce`, `wifi.status`, and signal telemetry.
  - Host local `/health`, `/metrics`, `/whoami` endpoints for verification.

- **Ops Portal (CYD)**
  - Dedicated field display with orientation-as-function:
    - **Landscape = Utility Mode** (status + visualizer + action panel).
    - **Portrait = Watch Mode** (full-screen visualizer, no buttons).
    - Tap anywhere in Watch Mode to show a temporary quick-stats overlay.

## Visual Model (Shared)

- **Hue** = device identity (stable hash)
- **Brightness** = recency
- **Saturation** = confidence
- **Glow** = correlation
- Smooth decay over time

## Spine Responsibilities

- Polls pi-logger `/v1/events`.
- Normalizes events + derives frames for visualization.
- Hosts spectrum UI and tool endpoints.
- Provides WebSocket streams for frames/events.

## Naming

- Umbrella: **SODS** (Strange Ops Dev Station)
- CLI command: `sods`
- Desktop app: **Dev Station**
- CYD device: **Ops Portal**
- Sensor nodes: **node-agent**
