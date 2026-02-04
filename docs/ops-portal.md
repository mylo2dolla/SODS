# Ops Portal (CYD)

Ops Portal is the embedded control surface and watch display for SODS. It is local-only and event-based.

## Architecture

- `firmware/ops-portal/portal-core`
  - Device-agnostic rendering + state + UI widgets.
- `firmware/ops-portal/portal-device-cyd`
  - CYD-specific hardware bindings (TFT, touch, Wi-Fi, orientation).

## Modes

- Landscape: Utility mode (actions + status panes).
- Portrait: Watch mode (full spectrum visualizer, no action buttons).
- Tap anywhere in watch mode to show a quick stats overlay (auto-hides).

## Station endpoints used

- `GET /api/portal/state`
- `GET /api/tools`
- `GET /api/flash`
- `POST /api/tool/run`
- `WS /ws/frames`

## Build + flash

Build:
```bash
cd firmware/ops-portal
pio run -e ops-portal
```

Stage:
```bash
/Users/letsdev/sods/SODS/tools/portal-cyd-stage.sh
```

Flash via Station:
- `http://localhost:9123/flash/portal-cyd`

## Wi-Fi + Station config

If the portal cannot connect, it starts a local setup AP:
- SSID: `SODS-Portal-Setup`
- Open `http://192.168.4.1` and enter:
  - Wi-Fi SSID / password
  - Station URL (e.g. `http://<mac-ip>:9123`)
  - Logger URL (e.g. `http://pi-logger.local:8088`)

Credentials and URLs persist in device storage.
