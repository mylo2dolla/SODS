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
SODS_LOCAL_LOG_PATH="/Users/letsdev/sods/SODS/data/local-events.ndjson" ./tools/sods start --pi-logger http://pi-logger.local:8088 --port 9123
```

Tools are runnable from any working directory. Use an absolute path or `cd` to the repo root before running `./tools/...`.
If executables lose their permissions, run `/Users/letsdev/sods/SODS/tools/permfix.sh`.

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
/Users/letsdev/sods/SODS/tools/devstation-build.sh
```

Run (starts station if needed and launches the app):
```bash
/Users/letsdev/sods/SODS/tools/devstation-run.sh
```

Install:
```bash
/Users/letsdev/sods/SODS/tools/devstation-install.sh
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

Stage Ops Portal CYD for station flashing:
```bash
/Users/letsdev/sods/SODS/tools/portal-cyd-stage.sh
```

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

- App connects to the local station at `http://localhost:9123`.
- If the station is not running, the app launches it as a child process.
- Tools load from `/api/tools`.
- Visualizer streams from `/ws/frames`.
- Flash buttons open:
  - `http://localhost:9123/flash/esp32`
  - `http://localhost:9123/flash/esp32c3`
  - `http://localhost:9123/flash/portal-cyd`
- Internal station views (tools/status) open inside the app; only Flash opens a browser window.

## Station LaunchAgent (optional)

Enable on login:
```bash
/Users/letsdev/sods/SODS/tools/launchagent-install.sh
```

Disable:
```bash
/Users/letsdev/sods/SODS/tools/launchagent-uninstall.sh
```

Status:
```bash
/Users/letsdev/sods/SODS/tools/launchagent-status.sh
```

Logs:
- `/Users/letsdev/sods/SODS/data/logs/station.launchd.log`

## Wi-Fi Scan (macOS)

Scan nearby SSIDs (uses `airport` when present, falls back to `wdutil`):
```bash
/Users/letsdev/sods/SODS/tools/sods wifi-scan
/Users/letsdev/sods/SODS/tools/sods wifi-scan --pattern 'esp|espgo|c3|sods|portal|ops'
```

## Tool Registry

Passive-only tools are defined in `docs/tool-registry.json`. The CLI exposes them via `/tools`, and the Dev Station “God Button” shows them in-app.

## Demo/Replays
```bash
./tools/sods stream --frames --out ./cli/sods/public/demo.ndjson
open "http://localhost:9123/?demo=1"
```

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

## Environment Override

The Dev Station app resolves the repo root from `SODS_ROOT` if set. Default fallback is `~/sods/SODS`.
