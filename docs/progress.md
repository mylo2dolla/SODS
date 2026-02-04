# SODS Progress

Date: 2026-02-04

## What Changed Today

- Canonical repo structure established under `firmware/`, `apps/`, `cli/`, `tools/`, and `docs/`.
- `node-agent` + `ops-portal` firmware moved into `firmware/`.
- Dev Station app moved into `apps/dev-station`.
- CLI/spine server moved into `cli/sods` and CLI commands updated to use `/v1/events` for IP discovery.
- Ops Portal refactored into `portal-core` + `portal-device-cyd` modules with orientation-as-function (Utility/Watch modes).
- ESP Web Tools staging/flash scripts preserved and wired for repo-root invocation.
- Legacy aliases (`tools/camutil`, `tools/cockpit`) retained as shims.
- Reference PDFs moved to `docs/reference`, archive zip to `docs/archive`, and data logs to `data/strangelab`.

## Current Architecture (Locked)

- Tier 0: **Dev Station (macOS)** = primary operator UI.
- Tier 1: **Pi Aux + Logger** = `/v1/events` source of truth.
- Tier 2: **node-agent** (ESP32/ESP32-C3) = sensor nodes emitting `node.announce` + `wifi.status`.
- **Ops Portal (CYD)** = dedicated field UI with Utility (landscape) + Watch (portrait) modes.

## Canonical Paths

- CLI + spine server: `cli/sods`
- Dev Station app: `apps/dev-station/DevStation.xcodeproj`
- Node agent firmware: `firmware/node-agent`
- Ops Portal firmware: `firmware/ops-portal`
- Scripts + shims: `tools`

## Commands (Canonical)

Spine dev:
```bash
cd cli/sods
npm install
npm run dev -- --pi-logger http://pi-logger.local:8088 --port 9123
```

CLI (event-based):
```bash
./tools/sods whereis <node_id>
./tools/sods open <node_id>
./tools/sods tail <node_id>
```

Node agent build + stage:
```bash
cd firmware/node-agent
./tools/build-stage-esp32dev.sh
./tools/build-stage-esp32c3.sh
```

Ops Portal build:
```bash
cd firmware/ops-portal
pio run -e ops-portal
```

CLI build required for `./tools/sods --help`:
```bash
cd cli/sods
npm install
npm run build
```

## Notes

- `/v1/events` only supports `node_id` + `limit`, so CLI filters client-side for `wifi.status` and `node.announce`.
- Ops Portal Watch Mode: tap anywhere to show a 2–3 stat overlay that auto-hides.
- CLI flags split: `--logger` for pi-logger, `--station` for spine endpoints.
