# Strange Ops Dev Station (SODS)

SODS is the spine: it ingests pi-logger events, normalizes into canonical events/frames, serves the spectrum UI, and powers the Dev Station app + CLI.

**Repo layout (canonical):**
- `apps/dev-station` (macOS Dev Station app)
- `cli/sods` (unified CLI + spine server)
- `firmware/node-agent` (ESP32/ESP32-C3 firmware + esp-web-tools)
- `firmware/ops-portal` (CYD Ops Portal firmware)
- `tools` (repo-wide scripts + compatibility shims)
- `docs` (progress + architecture)

Operational requirements:
- `docs/devstation-stack-requirements.md`

## Build/Run

**Spine + CLI**
```bash
cd cli/sods
npm install
npm run dev -- --pi-logger http://pi-aux.local:9101 --port 9123
```

Optional local capture (append-only NDJSON):
```bash
SODS_LOCAL_LOG_PATH="./data/logs/local-events.ndjson" ./tools/sods start --pi-logger http://pi-aux.local:9101 --port 9123
```

Tools are runnable from any working directory. Use an absolute path or `cd` to the repo root before running `./tools/...`.
If executables lose their permissions, run `./tools/permfix.sh`.

Build + run:
```bash
cd cli/sods
npm install
npm run build
node dist/cli.js start --pi-logger http://pi-aux.local:9101 --port 9123
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

Package + launcher (build app, install app, install one-click stack launcher):
```bash
./tools/devstation-package.sh
```

Install launcher only (includes cleanup of old launcher artifacts and creates Desktop aliases):
```bash
./tools/install-devstation-launcher.sh
```

Start the full local stack from the launcher script (Station bootstrap + full-fleet auto-heal + app launch):
```bash
./tools/launcher-up.sh
```

Run full-fleet recovery directly:
```bash
./tools/control-plane-up.sh
```

Read compact fleet status (`ok`, `degraded`, `offline`):
```bash
./tools/control-plane-status.sh
echo $?
```

Status/log artifacts:
- `~/Library/Logs/SODS/control-plane-status.json`
- `~/Library/Logs/SODS/control-plane-up.log`
- `~/Library/Logs/SODS/launcher.log`

Clean old launcher/app artifacts:
```bash
./tools/cleanup-old-devstation-assets.sh
```

The Dashboard now includes a **Stack Status** panel with reconnect actions:
- Reconnect Station
- Restart Pi-Aux relay
- Reconnect control-plane checks
- Reconnect entire stack
- Reconnect Full Fleet
- View Fleet Status

Manual full-fleet recovery commands:
```bash
ssh -o ConnectTimeout=5 pi@192.168.8.114 'sudo systemctl restart strangelab-token.service strangelab-god-gateway.service strangelab-ops-feed.service strangelab-exec-agent@pi-aux.service && sudo systemctl --no-pager --full status strangelab-token.service strangelab-god-gateway.service strangelab-ops-feed.service | sed -n "1,120p"'

cd /Users/letsdev/SODS-main/ops/strangelab-control-plane
./scripts/push-and-install-remote.sh pi@192.168.8.114 pi-aux
./scripts/push-and-install-remote.sh pi@192.168.8.160 pi-logger

cd /Users/letsdev/SODS-main
./tools/verify-control-plane.sh
./tools/verify-all.sh
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
- `sods start --pi-logger` uses `PI_LOGGER_URL`/`PI_LOGGER`, else `http://${AUX_HOST:-pi-aux.local}:9101`
- `sods whereis/open/tail --logger` uses first URL from `PI_LOGGER_URL`/`PI_LOGGER`, else `http://${AUX_HOST:-pi-aux.local}:9101`
- `sods spectrum/tools/stream --station` uses `SODS_STATION_URL`/`SODS_BASE_URL`/`SODS_STATION`/`STATION_URL`, else `http://localhost:9123`

Examples:
```bash
./tools/sods whereis lab-esp32-01
./tools/sods open lab-esp32-01
./tools/sods tail lab-esp32-01
./tools/sods spectrum
```

## Dev Station App Flow

- App connects to Station at `SODS_STATION_URL`/`SODS_BASE_URL`/`STATION_URL` (default `http://127.0.0.1:9123`).
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

Runtime root resolution:
- `SODS_ROOT` (if explicitly set)
- else `~/SODS` (only if that directory already exists)
- else repo root (`/Users/letsdev/SODS-main`)

Local runtime outputs (operational artifacts, not source-controlled):
- `<runtime-root>/inbox`
- `<runtime-root>/workspace`
- `<runtime-root>/reports`
- `<runtime-root>/.shipper`

Canonical source-controlled locations:
- `docs/tool-registry.json`, `docs/presets.json`, `docs/runbooks.json`
- app/runtime code under `apps/`, `cli/`, `firmware/`, `tools/`, `docs/`

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
