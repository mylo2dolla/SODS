# Strange Ops Dev Station (SODS)

SODS is the spine: it ingests pi-logger events, normalizes into canonical events/frames, serves the spectrum UI, and powers the Dev Station app + CLI.

**Repo layout (canonical):**
- `apps/dev-station` (macOS Dev Station app)
- `cli/sods` (unified CLI + spine server)
- `firmware/node-agent` (ESP32/ESP32-C3 firmware + esp-web-tools)
- `firmware/ops-portal` (CYD Ops Portal firmware)
- `tools` (repo-wide scripts + compatibility shims)
- `docs` (progress + architecture)

## Build/Run

**Spine + CLI**
```bash
cd cli/sods
npm install
npm run dev -- --pi-logger http://pi-logger.local:8088 --port 9123
```

Optional local capture (append-only NDJSON):
```bash
SODS_LOCAL_LOG_PATH="./data/logs/local-events.ndjson" ./tools/sods start --pi-logger http://pi-logger.local:8088 --port 9123
```

Tools are runnable from any working directory. Use an absolute path or `cd` to the repo root before running `./tools/...`.
If executables lose their permissions, run `./tools/permfix.sh`.

Build + run:
```bash
cd cli/sods
npm install
npm run build
node dist/cli.js start --pi-logger http://pi-logger.local:8088 --port 9123
```

Open spectrum:
```bash
./tools/sods spectrum
```

**Dev Station (macOS app)**
Build:
```bash
./tools/devstation-build.sh
```

Run (starts Station backend if needed and launches the app):
```bash
./tools/devstation-run.sh
```

Run Station backend only (no UI):
```bash
./tools/station start
./tools/station status
./tools/station logs
```

Install:
```bash
./tools/devstation-install.sh
```

**Ops Portal (CYD)**
```bash
cd firmware/ops-portal
pio run -e ops-portal
```

**Node Agent (ESP32 / ESP32-C3)**
```bash
cd firmware/node-agent
./tools/build-stage-esp32dev.sh
./tools/build-stage-esp32c3.sh
```

Launch local ESP Web Tools:
```bash
./tools/flash-esp32dev.sh
./tools/flash-esp32c3.sh
```

CLI preflight (no write):
```bash
./tools/flash-diagnose.sh esp32
./tools/flash-diagnose.sh esp32c3
./tools/flash-diagnose.sh portal-cyd
./tools/flash-diagnose.sh p4
```

Stage Ops Portal CYD for station flashing:
```bash
./tools/portal-cyd-stage.sh
```
Docs:
- `docs/ops-portal.md`

## CLI (Unified)

Defaults:
- `sods whereis/open/tail` use `http://pi-logger.local:8088` via `--logger`
- `sods spectrum/tools/stream` use `http://localhost:9123` via `--station`

Examples:
```bash
./tools/sods whereis lab-esp32-01
./tools/sods open lab-esp32-01
./tools/sods tail lab-esp32-01
./tools/sods spectrum
```

## Dev Station App Flow

- App connects to Station at `SODS_STATION_URL` (default `http://192.168.8.214:9123`).
- If the station is not running, the app launches it as a child process.
- Tools load from `/api/tools`.
- Visualizer streams from `/ws/frames`.
- Flash buttons open:
  - `http://localhost:9123/flash/esp32`
  - `http://localhost:9123/flash/esp32c3`
  - `http://localhost:9123/flash/portal-cyd`
  - `http://localhost:9123/flash/p4`
- Flash diagnostics API: `http://localhost:9123/api/flash/diagnostics`
- Internal station views (tools/status) open inside the app; only Flash opens a browser window.

## Station LaunchAgent (optional)

Enable on login:
```bash
./tools/launchagent-install.sh
```

Disable:
```bash
./tools/launchagent-uninstall.sh
```

Status:
```bash
./tools/launchagent-status.sh
```

Logs:
- `./data/logs/station.launchd.log`

## Wi-Fi Scan (macOS)

Scan nearby SSIDs (uses `airport` when present, falls back to `wdutil`):
```bash
./tools/sods wifi-scan
./tools/sods wifi-scan --pattern 'esp|espgo|c3|sods|portal|ops'
```

## Tool Registry

Passive-only tools are defined in `docs/tool-registry.json`. The CLI exposes them via `/tools`, and the Dev Station “God Button” shows them in-app.

## Tool Builder + Presets

User tools:
- Registry: `docs/tool-registry.user.json` (gitignored)
- Scripts: `tools/user/<toolName>.(sh|py|mjs)`

Presets:
- Official: `docs/presets.json`
- User: `docs/presets.user.json` (gitignored)

CLI examples:
```bash
./tools/sods tool add --entry '{"name":"net.sample","title":"Sample","runner":"shell","kind":"inspect"}' --script ./tools/user/net.sample.sh
./tools/sods preset add --preset '{"id":"frontdoor.snapshot","kind":"single","tool":"camera.viewer","input":{"ip":"192.168.1.10","path":"/"}}'
curl -s -X POST http://localhost:9123/api/runbook/run -H 'Content-Type: application/json' -d '{"name":"triangulation","input":{}}'
./tools/sods scratch --runner shell --input '{}' < /tmp/snippet.sh
```

## Runbooks

Runbooks are first-class actions defined in `docs/runbooks.json` and exposed via:
- `GET /api/runbooks`
- `POST /api/runbook/run`

Dev Station renders runbooks in-app (no external browser).

Audit helper:
```bash
./tools/audit-tools.sh
./tools/audit-repo.sh
```

## Local Storage Paths

Dev Station stores local artifacts under `~/SODS`:
- `~/SODS/inbox`
- `~/SODS/workspace`
- `~/SODS/reports`
- `~/SODS/.shipper`
- `~/SODS/oui/oui_combined.txt`

## Flashing Paths

- Manifests:
  - `firmware/node-agent/esp-web-tools/manifest.json` (ESP32)
  - `firmware/node-agent/esp-web-tools/manifest-esp32c3.json` (ESP32-C3)
- Firmware staging output:
  - `firmware/node-agent/esp-web-tools/firmware/esp32dev/*`
  - `firmware/node-agent/esp-web-tools/firmware/esp32c3/*`

## Compatibility Shims

Legacy aliases remain:
- `tools/camutil`
- `tools/devstation`
- `tools/cockpit`

Canonical CLI:
- `tools/sods`

Canonical Station backend entrypoint:
- `tools/station`

## Environment Override

The Dev Station app resolves the repo root from `SODS_ROOT` if set. Default fallbacks include `~/SODS-main` and the current working directory.
