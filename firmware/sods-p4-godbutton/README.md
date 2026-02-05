# SODS ESP32-P4 God Button Firmware

Firmware name: `sods-p4-godbutton`  
Version: `0.1.0`  
Role: `field-tool`  
Node type: `esp32-p4`

## Hardware
Board: Waveshare ESP32-P4-WIFI6-M (SKU 31647)  
Markings: ESP32-P4-WIFI6  
Chips:
- ESP32-P4 main MCU
- ESP32-C6-MINI-1 module (Wi-Fi 6 + BLE)

Ports / connectors:
- USB-C (power/program/debug)
- microSD slot (top)
- FPC connectors: DISPLAY and CAMERA (MIPI)
- JST speaker header: SPK
- Buttons: RESET and BOOT

## Capabilities (v0)
- `wifi.scan.passive`
- `ble.scan.passive` (reports unsupported until BLE is available)
- `buffer.ring`
- `export.ndjson`
- `http.control`

## Event Envelope
All emitted records are NDJSON lines:

```
{"node_id":"p4-<id>","ts":<unix_ms>,"domain":"wifi|ble|sys","type":"...","data":{...}}
```

`ts` is milliseconds since epoch. If RTC time is not set, the firmware uses uptime and reports `time_source: "uptime"` in `/status`.

## HTTP API

Status / identity
- `GET /status`
- `GET /identity`

God Button
- `POST /god`

Explicit actions
- `POST /scan/once` body: `{ "domains": ["wifi","ble"], "duration_ms": 5000 }`
- `POST /mode/set` body: `{ "mode": "idle|field|relay" }`
- `POST /buffer/export`
- `POST /buffer/clear`

Responses:

```
{ "ok": true, "action": "...", "details": { ... } }
```

Errors:

```
{ "ok": false, "error": "...", "details": { ... } }
```

## Build / Flash

From repo root:

```
tools/p4-build.sh
tools/p4-flash.sh
tools/p4-monitor.sh
```

## Defaults

Defaults live in `sdkconfig.defaults`:
- SSID: `espgo`
- PASS: `12345678`
- HTTP port: `8080`
