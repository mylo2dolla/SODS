#include "http_server.h"
#include "god_button.h"
#include "event_emit.h"
#include "ring_buffer.h"
#include "identity.h"
#include "time_sync.h"
#include "scan_wifi.h"
#include "scan_ble.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "cJSON.h"

static const char *TAG = "http";
static httpd_handle_t g_server = NULL;

static const wifi_scan_state_t *wifi_state(void) {
  const wifi_scan_state_t *state = scan_wifi_state();
  return state;
}

static const ble_scan_state_t *ble_state(void) {
  const ble_scan_state_t *state = scan_ble_state();
  return state;
}

static esp_err_t send_json(httpd_req_t *req, const char *json) {
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, json, HTTPD_RESP_USE_STRLEN);
}

static cJSON *parse_body(httpd_req_t *req) {
  int len = req->content_len;
  if (len <= 0) return NULL;
  char *buf = calloc(1, len + 1);
  if (!buf) return NULL;
  int read = httpd_req_recv(req, buf, len);
  if (read <= 0) {
    free(buf);
    return NULL;
  }
  cJSON *json = cJSON_Parse(buf);
  free(buf);
  return json;
}

static esp_err_t status_handler(httpd_req_t *req) {
  const identity_t *id = identity_get();
  const god_context_t *ctx = god_button_context();
  cJSON *root = cJSON_CreateObject();
  cJSON_AddStringToObject(root, "node_id", id->node_id);
  cJSON_AddStringToObject(root, "role", id->role);
  cJSON_AddStringToObject(root, "version", id->version);
  cJSON_AddStringToObject(root, "type", id->type);
  cJSON_AddNumberToObject(root, "ts", (double)time_sync_unix_ms());
  cJSON_AddStringToObject(root, "time_source", time_sync_source());
  cJSON *state = cJSON_AddObjectToObject(root, "state");
  cJSON_AddNumberToObject(state, "mode", ctx->mode);
  cJSON_AddBoolToObject(state, "wifi_connected", ctx->wifi_connected);
  cJSON_AddNumberToObject(state, "last_scan_ms", ctx->last_scan_ms);
  cJSON_AddNumberToObject(state, "buffer_count", ctx->buffer_count);
  cJSON_AddBoolToObject(state, "buffer_pressure", ctx->buffer_pressure);
  cJSON_AddBoolToObject(state, "devstation_reachable", ctx->devstation_reachable);
  cJSON_AddBoolToObject(state, "logger_reachable", ctx->logger_reachable);
  const wifi_scan_state_t *wifi = wifi_state();
  const ble_scan_state_t *ble = ble_state();
  cJSON_AddNumberToObject(state, "wifi_last_count", wifi ? wifi->last_count : 0);
  cJSON_AddNumberToObject(state, "ble_last_count", ble ? ble->last_count : 0);
  char *out = cJSON_PrintUnformatted(root);
  cJSON_Delete(root);
  esp_err_t res = send_json(req, out ? out : "{}");
  if (out) free(out);
  return res;
}

static esp_err_t identity_handler(httpd_req_t *req) {
  const identity_t *id = identity_get();
  cJSON *root = cJSON_CreateObject();
  cJSON_AddStringToObject(root, "node_id", id->node_id);
  cJSON_AddStringToObject(root, "role", id->role);
  cJSON_AddStringToObject(root, "version", id->version);
  cJSON_AddStringToObject(root, "type", id->type);
  char *out = cJSON_PrintUnformatted(root);
  cJSON_Delete(root);
  esp_err_t res = send_json(req, out ? out : "{}");
  if (out) free(out);
  return res;
}

static esp_err_t god_handler(httpd_req_t *req) {
  bool ok = god_button_run_all();
  cJSON *root = cJSON_CreateObject();
  cJSON_AddBoolToObject(root, "ok", ok);
  cJSON_AddStringToObject(root, "action", "god");
  cJSON *details = cJSON_AddObjectToObject(root, "details");
  cJSON_AddNumberToObject(details, "buffer_count", (double)ring_buffer_count(event_emit_buffer()));
  char *out = cJSON_PrintUnformatted(root);
  cJSON_Delete(root);
  esp_err_t res = send_json(req, out ? out : "{}");
  if (out) free(out);
  return res;
}

static esp_err_t mode_set_handler(httpd_req_t *req) {
  cJSON *json = parse_body(req);
  if (!json) return send_json(req, "{\"ok\":false,\"error\":\"invalid_json\"}");
  cJSON *mode = cJSON_GetObjectItem(json, "mode");
  if (!cJSON_IsString(mode)) {
    cJSON_Delete(json);
    return send_json(req, "{\"ok\":false,\"error\":\"missing_mode\"}");
  }
  god_context_t ctx = *god_button_context();
  if (strcmp(mode->valuestring, "idle") == 0) ctx.mode = MODE_IDLE;
  else if (strcmp(mode->valuestring, "field") == 0) ctx.mode = MODE_FIELD;
  else if (strcmp(mode->valuestring, "relay") == 0) ctx.mode = MODE_RELAY;
  god_button_update_context(&ctx);
  cJSON_Delete(json);
  return send_json(req, "{\"ok\":true,\"action\":\"mode.set\"}");
}

static esp_err_t scan_once_handler(httpd_req_t *req) {
  cJSON *json = parse_body(req);
  bool do_wifi = true;
  bool do_ble = true;
  if (json) {
    cJSON *domains = cJSON_GetObjectItem(json, "domains");
    if (cJSON_IsArray(domains)) {
      do_wifi = false;
      do_ble = false;
      cJSON *item = NULL;
      cJSON_ArrayForEach(item, domains) {
        if (cJSON_IsString(item)) {
          if (strcmp(item->valuestring, "wifi") == 0) do_wifi = true;
          if (strcmp(item->valuestring, "ble") == 0) do_ble = true;
        }
      }
    }
  }
  if (json) cJSON_Delete(json);
  bool ok = true;
  wifi_scan_state_t *wifi = (wifi_scan_state_t *)wifi_state();
  ble_scan_state_t *ble = (ble_scan_state_t *)ble_state();
  if (do_wifi && wifi) ok &= scan_wifi_run(wifi);
  if (do_ble && ble) ok &= scan_ble_run(ble);
  return send_json(req, ok ? "{\"ok\":true,\"action\":\"scan.once\"}" : "{\"ok\":false,\"action\":\"scan.once\"}");
}

static esp_err_t buffer_export_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/plain");
  const ring_buffer_t *rb = event_emit_buffer();
  size_t count = ring_buffer_count(rb);
  for (size_t i = 0; i < count; ++i) {
    const char *line = ring_buffer_get(rb, i);
    if (!line) continue;
    httpd_resp_sendstr_chunk(req, line);
    httpd_resp_sendstr_chunk(req, "\n");
  }
  return httpd_resp_send_chunk(req, NULL, 0);
}

static esp_err_t buffer_clear_handler(httpd_req_t *req) {
  ring_buffer_t *rb = (ring_buffer_t *)event_emit_buffer();
  ring_buffer_clear(rb);
  return send_json(req, "{\"ok\":true,\"action\":\"buffer.clear\"}");
}

void http_server_start(void) {
  if (g_server) return;
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = CONFIG_SODS_HTTP_PORT;
  if (httpd_start(&g_server, &config) != ESP_OK) {
    ESP_LOGE(TAG, "Failed to start HTTP server");
    return;
  }

  httpd_uri_t status = { .uri = "/status", .method = HTTP_GET, .handler = status_handler };
  httpd_uri_t identity = { .uri = "/identity", .method = HTTP_GET, .handler = identity_handler };
  httpd_uri_t god = { .uri = "/god", .method = HTTP_POST, .handler = god_handler };
  httpd_uri_t scan = { .uri = "/scan/once", .method = HTTP_POST, .handler = scan_once_handler };
  httpd_uri_t mode = { .uri = "/mode/set", .method = HTTP_POST, .handler = mode_set_handler };
  httpd_uri_t export_buf = { .uri = "/buffer/export", .method = HTTP_POST, .handler = buffer_export_handler };
  httpd_uri_t clear_buf = { .uri = "/buffer/clear", .method = HTTP_POST, .handler = buffer_clear_handler };

  httpd_register_uri_handler(g_server, &status);
  httpd_register_uri_handler(g_server, &identity);
  httpd_register_uri_handler(g_server, &god);
  httpd_register_uri_handler(g_server, &scan);
  httpd_register_uri_handler(g_server, &mode);
  httpd_register_uri_handler(g_server, &export_buf);
  httpd_register_uri_handler(g_server, &clear_buf);
}
