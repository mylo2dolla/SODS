#include "scan_wifi.h"
#include "event_emit.h"
#include "time_sync.h"
#include "esp_wifi.h"
#include "esp_log.h"
#include <string.h>

static const char *TAG = "scan_wifi";
static wifi_scan_state_t *g_state = NULL;

void scan_wifi_init(wifi_scan_state_t *state) {
  if (!state) return;
  g_state = state;
  state->last_scan_ms = 0;
  state->last_count = 0;
}

bool scan_wifi_run(wifi_scan_state_t *state) {
  if (!state) return false;
  if (!g_state) g_state = state;
  wifi_scan_config_t cfg = {
    .ssid = NULL,
    .bssid = NULL,
    .channel = 0,
    .show_hidden = true,
    .scan_type = CONFIG_SODS_WIFI_SCAN_ACTIVE ? WIFI_SCAN_TYPE_ACTIVE : WIFI_SCAN_TYPE_PASSIVE,
    .scan_time = {
      .active = {
        .min = 50,
        .max = CONFIG_SODS_WIFI_SCAN_TIME_MS
      },
      .passive = CONFIG_SODS_WIFI_SCAN_TIME_MS
    }
  };

  esp_err_t err = esp_wifi_scan_start(&cfg, true);
  if (err != ESP_OK) {
    ESP_LOGW(TAG, "scan start failed: %s", esp_err_to_name(err));
    event_emit_line("wifi", "scan.error", "{\"error\":\"scan_start_failed\"}");
    return false;
  }

  uint16_t ap_count = 0;
  esp_wifi_scan_get_ap_num(&ap_count);
  wifi_ap_record_t *records = calloc(ap_count, sizeof(wifi_ap_record_t));
  if (!records) {
    event_emit_line("wifi", "scan.error", "{\"error\":\"oom\"}");
    return false;
  }

  if (esp_wifi_scan_get_ap_records(&ap_count, records) != ESP_OK) {
    free(records);
    event_emit_line("wifi", "scan.error", "{\"error\":\"scan_records_failed\"}");
    return false;
  }

  for (uint16_t i = 0; i < ap_count; ++i) {
    char data[256];
    wifi_ap_record_t *ap = &records[i];
    char ssid[33] = {0};
    memcpy(ssid, ap->ssid, sizeof(ap->ssid));
    snprintf(data, sizeof(data),
             "{\"ssid\":\"%s\",\"bssid\":\"%02x:%02x:%02x:%02x:%02x:%02x\",\"rssi\":%d,\"channel\":%d}",
             ssid,
             ap->bssid[0], ap->bssid[1], ap->bssid[2],
             ap->bssid[3], ap->bssid[4], ap->bssid[5],
             ap->rssi,
             ap->primary);
    event_emit_line("wifi", "scan.ap", data);
  }

  free(records);
  state->last_scan_ms = (uint32_t)time_sync_unix_ms();
  state->last_count = ap_count;
  event_emit_line("wifi", "scan.summary", "{\"ok\":true}");
  return true;
}

const wifi_scan_state_t *scan_wifi_state(void) {
  return g_state;
}
