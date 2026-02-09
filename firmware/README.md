# SODS Firmware

Canonical firmware contract lives here and is board-driven by:

- `firmware/boards.json`

Each app stages web-flash artifacts under:

- `firmware/<app>/esp-web-tools/firmware/<board_id>/<version>/`

with required files:

- `bootloader.bin`
- `partition-table.bin`
- `firmware.bin`
- `buildinfo.json`
- `sha256sums.txt`

Legacy non-versioned stage folders are still generated for compatibility with existing flash pages.

## One-command staging

From `firmware/`:

```bash
npm run fw:stage:all -- --version devstation
```

This builds/stages:

- Node Agent (`esp32-devkitv1`, `esp32-c3`)
- Ops Portal CYD (`cyd-2432s028`)
- P4 God Button (`waveshare-esp32p4`)

## Verification

From `firmware/`:

```bash
npm run fw:verify
```

Or from repo root:

```bash
./tools/check-firmware.sh
```

## Flash preflight (no write)

From repo root:

```bash
./tools/flash-diagnose.sh esp32
./tools/flash-diagnose.sh esp32c3
./tools/flash-diagnose.sh portal-cyd
./tools/flash-diagnose.sh p4
```
