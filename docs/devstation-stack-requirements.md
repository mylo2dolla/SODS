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
- `Full-fleet control-plane bootstrap`:
  - Command: `/Users/letsdev/SODS-main/tools/control-plane-up.sh`
  - Status helper: `/Users/letsdev/SODS-main/tools/control-plane-status.sh`
  - Status artifact: `/Users/letsdev/Library/Logs/SODS/control-plane-status.json`
  - Log artifact: `/Users/letsdev/Library/Logs/SODS/control-plane-up.log`
- `Pi-Aux relay`:
  - Managed in-app by `PiAuxStore` and auto-started by app lifecycle

## Launch Behavior
- Triggering `/Applications/DevStation Stack.app` must:
  1. Bootstrap Station if not healthy.
  2. Run full-fleet auto-heal via `/Users/letsdev/SODS-main/tools/control-plane-up.sh` with hard timeout (`CONTROL_PLANE_TIMEOUT_S`, default `20` seconds).
  3. Launch `/Applications/Dev Station.app`.
- Launcher must always open Dev Station even if remote recovery is degraded/offline/timeouts.
- Dev Station app startup must:
  1. Ensure Station is running for local Station URLs.
  2. Ensure Pi-Aux relay is running.
  3. Refresh control-plane checks.
  4. Read and display the fleet status artifact.

## In-App Status/Reconnect Panel
- Dashboard must expose a `Stack Status` card with:
  - Station status
  - Pi-Aux relay status
  - Pi-logger status
  - Control-plane aggregate status
  - Fleet auto-heal status
- Reconnect actions must be available from that panel:
  - Reconnect Station
  - Restart Pi-Aux relay
  - Reconnect control-plane checks
  - Reconnect entire stack
  - Reconnect Full Fleet
  - View Fleet Status
- Reconnect Full Fleet runs `/Users/letsdev/SODS-main/tools/control-plane-up.sh` in background and refreshes rows for:
  - `pi-aux`
  - `pi-logger`
  - `mac-agents`

## Full-Fleet Script Contracts
- `/Users/letsdev/SODS-main/tools/control-plane-up.sh`
  - Alias-first, direct-IP fallback:
    - pi-aux: `aux`, then `pi@192.168.8.114`
    - pi-logger: `vault`, then `pi@192.168.8.160`
    - mac agents: `mac8`, `mac16`, then configured env values
  - Health probes:
    - token POST: `http://192.168.8.114:9123/token`
    - god health: `http://192.168.8.114:8099/health`
    - ops feed health: `http://192.168.8.114:9101/health`
    - vault health: `http://192.168.8.160:8088/health`
  - Recovery order:
    1. `systemctl restart` / launchd kickstart
    2. bootstrap reinstall using `/Users/letsdev/SODS-main/ops/strangelab-control-plane/scripts/push-and-install-remote.sh`
  - Exit code:
    - `0` when all targets are healthy
    - `1` when degraded/offline
- `/Users/letsdev/SODS-main/tools/control-plane-status.sh`
  - Prints one of `ok`, `degraded`, `offline`
  - Exit code:
    - `0` for healthy
    - `1` for degraded/offline
    - `2` when status file is missing or invalid

## Failure Semantics
- Remote failures never block local app launch.
- Unreachable targets are marked in JSON as `reachable: false` and surfaced in dashboard rows.
- If units are missing/broken after restart, bootstrap install is attempted and result is logged in target actions.

## Manual Recovery Commands
```bash
ssh -o ConnectTimeout=5 pi@192.168.8.114 'sudo systemctl restart strangelab-token.service strangelab-god-gateway.service strangelab-ops-feed.service strangelab-exec-agent@pi-aux.service && sudo systemctl --no-pager --full status strangelab-token.service strangelab-god-gateway.service strangelab-ops-feed.service | sed -n "1,120p"'

cd /Users/letsdev/SODS-main/ops/strangelab-control-plane
./scripts/push-and-install-remote.sh pi@192.168.8.114 pi-aux
./scripts/push-and-install-remote.sh pi@192.168.8.160 pi-logger

cd /Users/letsdev/SODS-main
./tools/verify-control-plane.sh
./tools/verify-all.sh
```

## Prerequisites
- SSH key auth for `aux`, `vault`, and IP fallbacks.
- Remote sudo privileges for service management.
- Network can be intermittent; fleet scripts must degrade gracefully.

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
