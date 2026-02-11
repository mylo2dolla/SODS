#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "identity.h"
#include "ring_buffer.h"
#include "event_emit.h"
#include "time_sync.h"
#include "god_button.h"
#include "scan_wifi.h"
#include "scan_ble.h"
#include "http_server.h"

static const char *TAG = "app_main";

static ring_buffer_t g_ring;
static wifi_scan_state_t g_wifi_state;
static ble_scan_state_t g_ble_state;

static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data) {
  if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
    esp_wifi_connect();
  } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
    esp_wifi_connect();
  }
}

static void ip_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data) {
  if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
    ESP_LOGI(TAG, "Wi-Fi connected");
  }
}

static void wifi_init(void) {
#if defined(CONFIG_ESP_WIFI_ENABLED) && CONFIG_ESP_WIFI_ENABLED
  ESP_ERROR_CHECK(esp_netif_init());
  ESP_ERROR_CHECK(esp_event_loop_create_default());
  esp_netif_create_default_wifi_sta();
  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_wifi_init(&cfg));
  ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL));
  ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &ip_event_handler, NULL));

  wifi_config_t wifi_config = { 0 };
  snprintf((char *)wifi_config.sta.ssid, sizeof(wifi_config.sta.ssid), "%s", CONFIG_ESP_WIFI_SSID);
  snprintf((char *)wifi_config.sta.password, sizeof(wifi_config.sta.password), "%s", CONFIG_ESP_WIFI_PASSWORD);
  wifi_config.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
  wifi_config.sta.pmf_cfg.capable = true;
  wifi_config.sta.pmf_cfg.required = false;

  ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
  ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
  ESP_ERROR_CHECK(esp_wifi_start());
#else
  ESP_LOGW(TAG, "Wi-Fi disabled in sdkconfig; skipping station init");
#endif
}

void app_main(void) {
  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    ESP_ERROR_CHECK(nvs_flash_init());
  }

  identity_t id;
  identity_init(&id);
  time_sync_init();
  ring_buffer_init(&g_ring, CONFIG_SODS_RING_CAPACITY);
  event_emit_init(&g_ring);
  scan_wifi_init(&g_wifi_state);
  scan_ble_init(&g_ble_state);
  god_button_init();

  wifi_init();
  http_server_start();

  ESP_LOGI(TAG, "sods-p4-godbutton started: %s", id.node_id);

  while (true) {
    god_context_t ctx = *god_button_context();
    ctx.buffer_count = (uint32_t)ring_buffer_count(&g_ring);
    ctx.buffer_pressure = ctx.buffer_count > (uint32_t)(CONFIG_SODS_RING_CAPACITY * 8 / 10);
#if defined(CONFIG_ESP_WIFI_ENABLED) && CONFIG_ESP_WIFI_ENABLED
    wifi_ap_record_t ap_info;
    ctx.wifi_connected = (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK);
#else
    ctx.wifi_connected = false;
#endif
    uint32_t last_wifi = g_wifi_state.last_scan_ms;
    uint32_t last_ble = g_ble_state.last_scan_ms;
    ctx.last_scan_ms = last_wifi > last_ble ? last_wifi : last_ble;
    god_button_update_context(&ctx);
    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}
