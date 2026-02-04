# Strange Lab Node Agent (ESP32)

PlatformIO firmware for ESP32 DevKit v1 (WROOM) and ESP32-C3 DevKitM-1.

## Golden Path (3 Steps)

1) Build + stage firmware:
```bash
./tools/build-stage-esp32dev.sh
./tools/build-stage-esp32c3.sh
```

2) Flash (opens ESP Web Tools):
```bash
./tools/flash-esp32dev.sh --port 8000
./tools/flash-esp32c3.sh --port 8000
```

3) Verify (no serial):
```bash
../../tools/sods whereis lab-esp32-01
../../tools/sods open lab-esp32-01
curl "http://pi-logger.local:8088/v1/events?node_id=lab-esp32-01&limit=5"
```

## Build + Stage (esp32dev)

```bash
./tools/build-stage-esp32dev.sh
```

## Flash (esp32dev)

```bash
./tools/flash-esp32dev.sh
```

Opens: `http://localhost:8000/esp-web-tools/`

## Build + Stage (esp32c3)

```bash
./tools/build-stage-esp32c3.sh
```

## Flash (esp32c3)

```bash
./tools/flash-esp32c3.sh
```

Opens: `http://localhost:8000/esp-web-tools/?chip=esp32c3`

## Find IP (no serial)

From pi-logger (latest announce):

```bash
curl -fsS "http://pi-logger.local:8088/v1/events?node_id=lab-esp32-01&limit=5"
```

SODS CLI:

```bash
../../tools/sods whereis lab-esp32-01
../../tools/sods open lab-esp32-01
```

## Verify (no serial)

Server-side events:

```bash
curl -fsS http://localhost:9123/health
```

Pi-logger IP discovery:

```bash
curl -fsS "http://pi-logger.local:8088/v1/events?node_id=lab-esp32-01&limit=10"
```

Device health (once IP is known):

```bash
curl http://<device-ip>/health
curl http://<device-ip>/whoami
curl http://<device-ip>/wifi
```

## Router Compatibility (WPA2 + Mixed)

- WPA2-PSK supported (AES)
- WPA/WPA2 mixed mode is accepted
- If `WIFI_FORCE_WPA2=1`, the station auth threshold enforces WPA2-PSK

## Firmware Wi-Fi Hardening

- `WIFI_FORCE_WPA2` (default `1`) forces WPA2-PSK auth threshold.
- `WIFI_RESET_ON_BOOT` (default `0`) clears stored Wi-Fi creds on boot when enabled.
- `WIFI_RETRY_BASE_MS`, `WIFI_RETRY_MAX_MS`, `WIFI_CONNECT_TIMEOUT_MS` control reconnect timing.
- `WIFI_PASSIVE_SCAN` enables passive AP inventory; `WIFI_SCAN_INTERVAL_MS` controls scan cadence.

## Event Schema

All events emitted to ingest follow:

- Required: `v`, `ts_ms`, `node_id`, `type`, `src`, `data`
- Optional: `seq`, `rssi`, `mac`, `err`, `meta`

Event types (minimum set):

- `node.boot`
- `node.heartbeat`
- `node.announce`
- `wifi.status`
- `wifi.ap_seen`
- `ingest.ok`
- `ingest.err`
- `ble.seen`
- `ble.batch` (optional)
- `probe.net`
- `probe.http`

Selected event data fields:

- `node.boot`: `ip`, `mac`, `hostname`, `fw_version`, `chip_model`, `sdk_version`, `ingest_url`
- `node.heartbeat`: `ip`, `mac`, `hostname`, `uptime_ms`, `wifi_rssi`, `queue_depth`
- `node.announce`: `node_id`, `ip`, `mac`, `hostname`, `ssid`, `rssi`, `gw`, `mask`, `dns`, `uptime_ms`
- `wifi.status`: `connected`, `state`, `ssid`, `ip`, `mac`, `hostname`, `rssi`, `gw`, `mask`, `dns`, `auth`, `reason`

## Device HTTP API

- `GET /health`
- `GET /metrics`
- `GET /config`
- `GET /whoami`
- `GET /wifi`
- `POST /probe`
- `GET /ble/latest?limit=N`
- `GET /ble/stats`
