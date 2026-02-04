# SODS Firmware

This folder contains SODS firmware projects. Each device is modular and replaceable.

## Node Agent

Path: `firmware/node-agent`

Build + stage for ESP Web Tools:
```bash
cd firmware/node-agent
./tools/build-stage-esp32dev.sh
./tools/build-stage-esp32c3.sh
```

## Ops Portal (CYD)

Architecture:
- `firmware/ops-portal/portal-core`: device-agnostic portal logic (state + render)
- `firmware/ops-portal/portal-device-cyd`: CYD-specific drivers + network

Build:
```bash
cd firmware/ops-portal
pio run -e ops-portal
```

Stage for web flashing:
```bash
/Users/letsdev/sods/SODS/tools/portal-cyd-stage.sh
```

Station flash page:
- `http://localhost:9123/flash/portal-cyd`

Notes:
- The CYD connects to Station for `/api/status`, `/api/tools`, and `/ws/frames`.
- Orientation controls mode: landscape = utility, portrait = watch.
