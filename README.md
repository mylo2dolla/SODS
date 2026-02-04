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
1. Open `apps/dev-station/CamUtil.xcodeproj` in Xcode.
2. Select the `CamUtil` scheme.
3. Build + run (app display name: Strange Ops Dev Station).

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

## CLI (Unified)

Defaults:
- `sods whereis/open/tail` use `http://pi-logger.local:8088` (`/v1/events`)
- `sods spectrum/tools/stream` use `http://localhost:9123`

Examples:
```bash
./tools/sods whereis lab-esp32-01
./tools/sods open lab-esp32-01
./tools/sods tail lab-esp32-01
./tools/sods spectrum
```

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
- `tools/cockpit`

Canonical CLI:
- `tools/sods`

## Environment Override

The Dev Station app resolves the repo root from `SODS_ROOT` if set. Default fallback is `~/sods/SODS`.
