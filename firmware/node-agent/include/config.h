#pragma once

#ifndef NODE_ID
#define NODE_ID ""
#endif

#ifndef FW_VERSION
#define FW_VERSION "0.1.0"
#endif

#ifndef INGEST_URL
#define INGEST_URL ""
#endif

#ifndef WIFI_SSID
#define WIFI_SSID ""
#endif

#ifndef WIFI_PASS
#define WIFI_PASS ""
#endif

#ifndef EVENT_SCHEMA_VERSION
#define EVENT_SCHEMA_VERSION 1
#endif

#ifndef EVENT_QUEUE_CAPACITY
#define EVENT_QUEUE_CAPACITY 300
#endif

#ifndef INGEST_TIMEOUT_MS
#define INGEST_TIMEOUT_MS 2000
#endif

#ifndef INGEST_BATCH_SIZE
#define INGEST_BATCH_SIZE 1
#endif

#ifndef WIFI_RESET_ON_BOOT
#define WIFI_RESET_ON_BOOT 0
#endif

#ifndef WIFI_FORCE_WPA2
#define WIFI_FORCE_WPA2 1
#endif

#ifndef WIFI_RETRY_BASE_MS
#define WIFI_RETRY_BASE_MS 1000
#endif

#ifndef WIFI_RETRY_MAX_MS
#define WIFI_RETRY_MAX_MS 30000
#endif

#ifndef WIFI_CONNECT_TIMEOUT_MS
#define WIFI_CONNECT_TIMEOUT_MS 15000
#endif

#ifndef WIFI_PASSIVE_SCAN
#define WIFI_PASSIVE_SCAN 1
#endif

#ifndef WIFI_SCAN_INTERVAL_MS
#define WIFI_SCAN_INTERVAL_MS 0
#endif

#ifndef WIFI_SCAN_PASSIVE_MS
#define WIFI_SCAN_PASSIVE_MS 200
#endif

#ifndef WIFI_AP_MAX_RESULTS
#define WIFI_AP_MAX_RESULTS 100
#endif

#ifndef WIFI_AP_DEDUPE_MS
#define WIFI_AP_DEDUPE_MS 0
#endif

#ifndef WIFI_AP_EMIT_PER_SCAN
#define WIFI_AP_EMIT_PER_SCAN 100
#endif

#ifndef ANNOUNCE_INTERVAL_MS
#define ANNOUNCE_INTERVAL_MS 60000
#endif

#ifndef BLE_OBS_CAPACITY
#define BLE_OBS_CAPACITY 128
#endif

#ifndef BLE_DEDUPE_MS
#define BLE_DEDUPE_MS 5000
#endif

#ifndef BLE_SCAN_INTERVAL_MS
#define BLE_SCAN_INTERVAL_MS 45
#endif

#ifndef BLE_SCAN_WINDOW_MS
#define BLE_SCAN_WINDOW_MS 15
#endif

#ifndef BLE_SCAN_RESTART_MS
#define BLE_SCAN_RESTART_MS 60000
#endif

#ifndef BLE_MAX_PER_SECOND
#define BLE_MAX_PER_SECOND 10
#endif

#ifndef PROBE_HTTP_TIMEOUT_MS
#define PROBE_HTTP_TIMEOUT_MS 1500
#endif

#ifndef EVENT_VALIDATE_JSON
#define EVENT_VALIDATE_JSON 1
#endif
