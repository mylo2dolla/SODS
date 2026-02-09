# Firmware Pipeline (Single Source of Truth)

This pipeline is the canonical path for build, stage, verify, flash, and claim.

## Board registry

All supported targets are defined in:

- `firmware/boards.json`

Current board IDs:

- `esp32-devkitv1`
- `esp32-c3`
- `cyd-2432s028`
- `waveshare-esp32p4`

## Stage artifacts

Build + stage all apps/boards for a version:

```bash
cd firmware
npm run fw:stage:all -- --version devstation
```

Per app:

```bash
cd firmware/node-agent
node ./tools/stage.mjs --board esp32-devkitv1 --version devstation
node ./tools/stage.mjs --board esp32-c3 --version devstation

cd firmware/ops-portal
node ./tools/stage.mjs --board cyd-2432s028 --version devstation

cd firmware/sods-p4-godbutton
node ./tools/stage.mjs --board waveshare-esp32p4 --version devstation
```

## Verify staged artifacts

```bash
cd firmware
npm run fw:verify
```

Root helper:

```bash
./tools/check-firmware.sh
```

## Flash (CLI)

Each firmware app includes a guarded flasher:

```bash
cd firmware/node-agent
node ./tools/flash.mjs --board esp32-devkitv1 --version devstation --port auto --erase
node ./tools/flash.mjs --board esp32-c3 --version devstation --port auto --erase

cd firmware/ops-portal
node ./tools/flash.mjs --board cyd-2432s028 --version devstation --port auto --erase

cd firmware/sods-p4-godbutton
node ./tools/flash.mjs --board waveshare-esp32p4 --version devstation --port auto --erase
```

Flash tool behavior:

- auto-detects serial port when `--port auto`
- blocks when port is busy (prints holder process)
- verifies connected chip via `esptool.py chip_id` before writing
- writes exact offsets from `boards.json`

## Claim after flash

Use the post-flash claim tool:

```bash
node ./tools/claim.mjs --board esp32-c3 --fw-version devstation --port auto
```

It will:

- read `CLAIM_CODE` from serial (or `--claim-code` override)
- send `node.claim` to God Gateway
- log `node.claim.intent` and `node.claim.result` to Vault

## Compatibility notes

- Legacy scripts (`tools/p4-stage.sh`, `tools/portal-cyd-stage.sh`, and node-agent `build-stage-*`) now delegate into the new staged pipeline.
- DevStation flash prep now validates actual manifest references + metadata files instead of hardcoded filenames.
