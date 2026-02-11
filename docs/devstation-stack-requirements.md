# Dev Station Stack Requirements

## Scope
This document defines the local Dev Station bootstrap stack for `/Users/letsdev/SODS-main`.

## Stack Components
- `Station backend`:
  - Command: `/Users/letsdev/SODS-main/tools/station start`
  - Default port: `9123`
  - Health endpoints:
    - `http://127.0.0.1:9123/health`
    - `http://127.0.0.1:9123/api/status`
- `Dev Station app`:
  - Bundle: `/Applications/Dev Station.app`
- `Dev Station launcher app`:
  - Bundle: `/Applications/DevStation Stack.app`
  - Entrypoint script: `/Users/letsdev/SODS-main/tools/launcher-up.sh`
- `Pi-Aux relay`:
  - Managed in-app by `PiAuxStore` and auto-started by app lifecycle

## Launch Behavior
- Triggering `/Applications/DevStation Stack.app` must:
  1. Bootstrap Station if not healthy.
  2. Probe control-plane endpoints (Vault, Token, God Gateway, Ops Feed) and log status.
  3. Launch `/Applications/Dev Station.app`.
- Dev Station app startup must:
  1. Ensure Station is running for local Station URLs.
  2. Ensure Pi-Aux relay is running.
  3. Refresh control-plane checks.

## In-App Status/Reconnect Panel
- Dashboard must expose a `Stack Status` card with:
  - Station status
  - Pi-Aux relay status
  - Pi-logger status
  - Control-plane aggregate status
- Reconnect actions must be available from that panel:
  - Reconnect Station
  - Restart Pi-Aux relay
  - Reconnect control-plane checks
  - Reconnect entire stack

## Packaging
- Packaging command:
  - `/Users/letsdev/SODS-main/tools/devstation-package.sh`
- This command must:
  1. Build Dev Station app.
  2. Install Dev Station app into `/Applications/Dev Station.app`.
  3. Install launcher app into `/Applications/DevStation Stack.app`.
  4. Create desktop shortcuts in `/Users/letsdev/Desktop/DevStation Launchers/`.

## Cleanup Policy
- Old launcher/app artifacts are removed by:
  - `/Users/letsdev/SODS-main/tools/cleanup-old-devstation-assets.sh`
- Cleanup targets include stale launcher names and legacy scaffold paths.
