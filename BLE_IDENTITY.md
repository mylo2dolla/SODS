# BLE Identity Model

## Why BLE IDs Drift

BLE addresses are not stable identity by themselves. Devices rotate random/private addresses, scanner payloads vary, and multiple scanners can see the same device at different moments.

The control-plane treats identity as an evidence problem, not a single-field lookup.

## Canonical Model

- `ble.observation`: raw sighting event from scanners.
- Candidate/device matching: score-based merge, never single-field trust.
- Canonical `device_id`: `ble:` + Base32(SHA-256(primary_fingerprint)) truncated to 26 chars.

## Observation Requirements

Each `ble.observation` should include:

- `ts_ms`
- `scanner_id`
- `rssi`
- `addr`, `addr_type`
- `adv_data_raw`
- `scan_rsp_raw` (optional)
- `name`
- `services` (UUID list)
- `mfg_company_id`, `mfg_data_raw`
- `tx_power` (optional)

## Fingerprints

- `fp_stable` (preferred):
  - normalized services
  - normalized manufacturer company ID
  - masked manufacturer bytes
  - normalized name pattern
- `fp_addr` (weak hint only):
  - address + address type hash

Manufacturer masking keeps known-stable bytes and masks volatile bytes. If no vendor rule exists, the heuristic keeps the first 4 bytes and masks the rest.

## Matching Scores

Score contributions:

- `+60` stable fingerprint match
- `+25` service overlap >= 50%
- `+20` same company and masked manufacturer match
- `+10` normalized name match
- `+10` public address match
- `-30` company conflict
- `-40` disjoint non-empty service sets

Thresholds:

- `>=70`: merge into existing device
- `50..69`: keep as candidate (more evidence needed)
- `<50`: new device

Multi-scanner merge window: 5 seconds when stable/masked signals agree.

## Persistence

SQLite registry:

- path default: `/var/lib/strangelab/registry.sqlite`
- tables:
  - `ble_devices`
  - `ble_fps`
  - `ble_aliases`

## Derived Events

`vault-ingest` derives and appends:

- `ble.device.seen`
- `ble.device.merged`

UI and spectrum logic should key BLE entities by `device_id`, not raw address.

## Rebuild Procedure

Replay recent observations and rebuild the registry:

```bash
node tools/ble-rebuild-registry.mjs --hours 24
```

Useful options:

- `--db <path>`
- `--events-root <path>`
- `--input <ndjson-file>`
- `--verbose`
