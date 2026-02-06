# SODS Audit Report

Date: 2026-02-04

## Scope
Audit and fixes across Station, Dev Station, Ops Portal, tools, and spectrum pipeline. No changes to historical data under `data/`.

## Present and Wired
- Station endpoints:
  - `GET /api/status`
  - `GET /api/tools`
  - `POST /api/tool/run`
  - `GET /api/runbooks`
  - `POST /api/runbook/run`
  - `GET /api/portal/state`
  - `GET /api/flash`
  - `GET /flash/*`
  - `WS /ws/frames`
- Runbooks:
  - `docs/runbooks.json` is the authoritative registry.
  - `/api/tools` includes runbooks as `kind=runbook` entries.
- Dev Station:
  - Tools/presets/runbooks open in-app sheets.
  - Only `/flash/*` uses external browser.
- Ops Portal:
  - Driven entirely by `/api/portal/state`.
  - Uses runbooks when available, then presets, then tools.
- Spectrum pipeline:
  - Frame engine emits frames -> Station broadcasts `/ws/frames`.
  - Dev Station renders frames; idle overlay shown when no frames/events.
  - Ops Portal consumes the same frame format.
- Tool registry:
  - Registry includes Wi‑Fi scan, camera viewer, network/portal utilities, and runbook support.
  - `tools/audit-tools.sh` checks coverage.

## Fixes Applied
- Added runbook registry/runner endpoints and report artifacts.
- Added runbook UI in Dev Station and wired to Station.
- Added runbook support to Ops Portal actions.
- Added simulated frames toggle in Dev Station for visualizer testing.
- Added tool coverage audit script.
- Added runbook user registry ignore to `.gitignore`.

## Remaining Incomplete
None known in code.

## Verification Commands
Station endpoints:
```bash
curl -s http://localhost:9123/api/status | head -c 400
curl -s http://localhost:9123/api/tools | head -c 400
curl -s http://localhost:9123/api/runbooks | head -c 400
curl -s http://localhost:9123/api/portal/state | head -c 400
```

Flash pages:
```bash
open http://localhost:9123/flash/esp32
open http://localhost:9123/flash/esp32c3
```

Tool coverage:
```bash
./tools/audit-tools.sh
```

Repo integrity:
```bash
./tools/audit-repo.sh
```

Dev Station visualizer:
- Open **Spectrum** view.
- Toggle **Simulate frames (dev)** if no live frames.

Runbook:
```bash
curl -s -X POST http://localhost:9123/api/runbook/run \
  -H 'Content-Type: application/json' \
  -d '{"name":"triangulation","input":{}}' | head -c 400
```
