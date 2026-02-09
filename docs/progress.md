# SODS Progress

Date: 2026-02-04

## What Changed Today

- 2026-02-04: Staged ESP32-P4 godbutton firmware for ESP Web Tools. Rebuilt and restaged node-agent firmware for ESP32 DevKit v1 (`esp32dev`) and ESP32-C3 (`esp32c3`). Staged ops-portal CYD firmware for ESP Web Tools.
- 2026-02-04: DevStation UI now enforces a single global node presentation (identity color + faint glow for active, grey/no glow for offline) across node cards and visualizer, with per-node Refresh wired to existing status/connect codepaths.
- Canonical repo structure established under `firmware/`, `apps/`, `cli/`, `tools/`, and `docs/`.
- `node-agent` + `ops-portal` firmware moved into `firmware/`.
- Dev Station app moved into `apps/dev-station`.
- CLI/spine server moved into `cli/sods` and CLI commands updated to use `/v1/events` for IP discovery.
- Ops Portal refactored into `portal-core` + `portal-device-cyd` modules with orientation-as-function (Utility/Watch modes).
- ESP Web Tools staging/flash scripts preserved and wired for repo-root invocation.
- Legacy aliases (`tools/camutil`, `tools/cockpit`) retained as shims.
- Reference PDFs moved to `docs/reference`, archive zip to `docs/archive`, and data logs to `data/strangelab`.
- Spectrum Frame Spec documented and wired across Station + Dev Station + Ops Portal.
- Frame engine now emits field positions (x/y/z) and tool runs inject local tool events into the visualizer stream.
- Dev Station spectrum field now supports tap overlay, node inspector, idle state, and improved depth/repulsion.
- Visualizer upgraded with focus mode, pulses, and field haze for a richer 4D feel.
- Visualizer now renders subtle bin arcs and supports pinning nodes for persistent tracking.
- Added gentle attraction for related sources plus orbital drift to make the field feel alive.
- Quick overlay now surfaces hottest source + current focus for at-a-glance context.
- Added replay scrub (last 60s window), connection lines, and legend overlay for signal families.
- Added replay autoplay + replay progress bar; pinned list now supports focus shortcuts.
- Ghost trails + scrub bar seek make the spectrum replay feel alive and controllable.
- Replay speed control added; ghost trails now decay by real time age.
- Ghost trails now tinted by source color for identity continuity.
- Focus labels now prefer real aliases (hostname/IP) when available.
- Alias resolution now uses station-provided alias map and local event fields (SSID/hostname/IP/BSSID) across the app.
- Added alias override editor in Dev Station; overrides persist locally and flow to portal via station.
- Added an Alias Manager panel for bulk edits (Tools toolbar button).
- Alias Manager supports delete actions.
- Alias Manager now supports JSON import/export.
- Added CLI alias commands and alias map in scan/device reports.
- Alias autocomplete added in inspector; wifi-scan now seeds SSID aliases for BSSID.
- Alias labels now shown in node list and pinned list for consistent display.
- Ops Portal visualizer now renders rings, pulses, and legend text for parity.
- Ops Portal: touch toggles focus mode + replay bar scrub (basic parity).
- Ops Portal status now shows focused source label and replay state.
- Focus label shortened to friendly suffix (last segment or last 6 chars).

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

Tools are runnable from any working directory. Use an absolute path or `cd` to the repo root before running `./tools/...`.
If executables lose permissions, run `./tools/permfix.sh`.

## Notes

- `/v1/events` only supports `node_id` + `limit`, so CLI filters client-side for `wifi.status` and `node.announce`.
- Ops Portal Watch Mode: tap anywhere to show a 2–3 stat overlay that auto-hides.
- CLI flags split: `--logger` for pi-logger, `--station` for spine endpoints.
- Tool Registry is now shared between CLI and Dev Station (`docs/tool-registry.json`), and only passive tools are exposed.
- 2026-02-04: Audit completed across Station, Dev Station, Ops Portal. Runbooks added with `/api/runbooks` and `/api/runbook/run`, portal state enriched (actions, quick stats, frames summary), and audit scripts added (`tools/audit-tools.sh`, `tools/audit-repo.sh`). See `docs/audit-report.md`.
- Visual model unified: hue=identity, brightness=recency, saturation=confidence, glow=correlation with smooth decay.
- Added launchd LaunchAgent (optional) for station auto-run on login.
- Flash UX: station serves `/api/flash` and `/flash/*` pages; Dev Station popover opens the right flasher URLs.
- Dev Station now uses in-app sheets for tools, API inspector, tool runner, and viewer; only Flash opens external browser.
- Dev Station local paths now default to the repo root (typically `~/SODS-main`), with legacy data under `~/SODS/*` migrated on first run.
- Added Tool Builder + Presets system (user registries in `docs/*.user.json`, scripts under `tools/user/`).
- Dev Station app bundling: fixed Info.plist validation to prevent “executable is missing” after install, added bundle validation in build/install/smoke, and forced CFBundleExecutable/CFBundleName to match the binary.

## LaunchAgent

Install:
```bash
./tools/launchagent-install.sh
```

Uninstall:
```bash
./tools/launchagent-uninstall.sh
```

Status:
```bash
./tools/launchagent-status.sh
```

Logs:
- `./data/logs/station.launchd.log`

## Flash Button

- Flash popover opens:
  - `http://localhost:9123/flash/esp32`
  - `http://localhost:9123/flash/esp32c3`
- If station is not running, Dev Station starts it and opens the URL once healthy.
