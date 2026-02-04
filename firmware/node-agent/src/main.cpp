#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <WebServer.h>
#include <NimBLEDevice.h>
#include <ESPmDNS.h>
#include <esp_wifi.h>
#include "config.h"

struct EventEntry {
  String json;
  bool logged;
};

class EventQueue {
 public:
  explicit EventQueue(size_t capacity) : capacity_(capacity) {
    buffer_ = new EventEntry[capacity_];
  }

  ~EventQueue() { delete[] buffer_; }

  bool push(const String &json) {
    if (count_ >= capacity_) {
      return false;
    }
    buffer_[tail_] = {json, false};
    tail_ = (tail_ + 1) % capacity_;
    count_++;
    return true;
  }

  bool empty() const { return count_ == 0; }

  EventEntry &front() { return buffer_[head_]; }

  EventEntry &at(size_t idx) { return buffer_[(head_ + idx) % capacity_]; }

  void pop() {
    if (count_ == 0) return;
    head_ = (head_ + 1) % capacity_;
    count_--;
  }

  size_t size() const { return count_; }

 private:
  EventEntry *buffer_ = nullptr;
  size_t capacity_ = 0;
  size_t head_ = 0;
  size_t tail_ = 0;
  size_t count_ = 0;
};

struct BleObservation {
  String mac;
  String name;
  int rssi = 0;
  uint8_t mfg_len = 0;
  uint8_t svc_count = 0;
  uint8_t adv_flags = 0;
  unsigned long last_seen_ms = 0;
  uint32_t seen_count = 0;
};

struct WifiApSeenCache {
  uint8_t bssid[6] = {0};
  unsigned long last_emit_ms = 0;
  bool valid = false;
};

static String buildEvent(const String &type, const String &dataJson,
                         const String &extraJson = "");
static void handleWifiScanDone();

static Preferences prefs;
static WebServer server(80);
static bool portalActive = false;
static bool serverStarted = false;
static EventQueue queue(EVENT_QUEUE_CAPACITY);

static BleObservation bleRing[BLE_OBS_CAPACITY];
static size_t bleRingCount = 0;
static size_t bleRingHead = 0;
static uint32_t bleRingOverwriteCount = 0;
static uint32_t bleDedupeCount = 0;

static uint32_t eventDropCount = 0;
static uint32_t bleSeenCount = 0;
static uint32_t bleScanRestartCount = 0;
static uint32_t bleScanStallCount = 0;
static unsigned long lastBleResultMs = 0;
static unsigned long lastBleRestartMs = 0;
static uint32_t bleMinHeap = 0;
static unsigned long loopMaxMs = 0;
static uint32_t eventInvalidCount = 0;

static const char *kDefaultNodeId = "node-unknown";
static const char *kDefaultIngestUrl = "http://pi-logger.local:8088/v1/ingest";

static String nodeId;
static String ingestUrl;
static uint32_t eventSeq = 0;
static unsigned long lastHeartbeatMs = 0;
static unsigned long nextSendAtMs = 0;
static uint8_t failCount = 0;
static unsigned long bleSecondStart = 0;
static uint8_t bleCountThisSecond = 0;

static uint32_t ingestOkCount = 0;
static uint32_t ingestErrCount = 0;
static unsigned long lastIngestOkMs = 0;
static unsigned long lastIngestErrMs = 0;
static String lastIngestErr = "";
static unsigned long lastIngestOkEventMs = 0;
static unsigned long lastIngestErrEventMs = 0;

static bool lastWifiConnected = false;
static String lastIpStr = "";
static String hostname = "";
static bool mdnsStarted = false;
static bool mdnsFailed = false;
static unsigned long lastAnnounceMs = 0;
static unsigned long nextWifiAttemptMs = 0;
static uint8_t wifiFailCount = 0;
static String wifiState = "disconnected";
static int lastDisconnectReason = -1;
static String lastAuthMode = "";
static unsigned long wifiConnectStartMs = 0;
static bool wifiScanInProgress = false;
static unsigned long lastWifiScanMs = 0;
static unsigned long lastWifiScanCompleteMs = 0;
static uint32_t wifiApSeenCount = 0;
static uint32_t wifiApDedupeCount = 0;
static uint32_t wifiApScanCount = 0;
static uint32_t wifiApDropCount = 0;
static WifiApSeenCache wifiApCache[WIFI_AP_MAX_RESULTS];

static String runtimeSsid;
static String runtimePass;

static NimBLEScan *bleScan = nullptr;

static inline void markIngestOk() {
  lastIngestOkMs = millis();
  lastIngestErr = "";
}

static inline void markIngestErr(const String &err) {
  lastIngestErr = err;
  lastIngestErrMs = millis();
}

static String jsonBool(bool v) { return v ? "true" : "false"; }

static String ipToString(const IPAddress &ip) {
  return String(ip[0]) + "." + String(ip[1]) + "." + String(ip[2]) + "." +
         String(ip[3]);
}

static String jsonEscape(const String &input) {
  String out;
  out.reserve(input.length() + 8);
  for (size_t i = 0; i < input.length(); i++) {
    char c = input[i];
    if (c == '"') {
      out += "\\\"";
    } else if (c == '\\') {
      out += "\\\\";
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else if (c == '\t') {
      out += "\\t";
    } else {
      out += c;
    }
  }
  return out;
}

static String jsonKV(const String &key, const String &value, bool quote = true) {
  if (quote) {
    return String("\"") + key + "\":\"" + jsonEscape(value) + "\"";
  }
  return String("\"") + key + "\":" + value;
}

static String jsonMaybeString(const String &key, const String &value) {
  if (value.length() == 0) {
    return String("\"") + key + "\":null";
  }
  return jsonKV(key, value);
}

static String bssidToString(const uint8_t *bssid) {
  char buf[18];
  snprintf(buf, sizeof(buf), "%02x:%02x:%02x:%02x:%02x:%02x",
           bssid[0], bssid[1], bssid[2], bssid[3], bssid[4], bssid[5]);
  return String(buf);
}

static bool isValidEventJson(const String &json) {
#if EVENT_VALIDATE_JSON
  return json.indexOf("\"v\"") >= 0 &&
         json.indexOf("\"ts_ms\"") >= 0 &&
         json.indexOf("\"node_id\"") >= 0 &&
         json.indexOf("\"type\"") >= 0 &&
         json.indexOf("\"src\"") >= 0 &&
         json.indexOf("\"data\"") >= 0;
#else
  (void)json;
  return true;
#endif
}

static const char *authModeToString(wifi_auth_mode_t mode) {
  switch (mode) {
    case WIFI_AUTH_OPEN: return "open";
    case WIFI_AUTH_WEP: return "wep";
    case WIFI_AUTH_WPA_PSK: return "wpa";
    case WIFI_AUTH_WPA2_PSK: return "wpa2";
    case WIFI_AUTH_WPA_WPA2_PSK: return "wpa_wpa2";
    case WIFI_AUTH_WPA2_ENTERPRISE: return "wpa2_ent";
    case WIFI_AUTH_WPA3_PSK: return "wpa3";
    case WIFI_AUTH_WPA2_WPA3_PSK: return "wpa2_wpa3";
    case WIFI_AUTH_WPA3_ENT_192: return "wpa3_ent_192";
    default: return "unknown";
  }
}

static void refreshAuthMode() {
  wifi_ap_record_t info;
  if (esp_wifi_sta_get_ap_info(&info) == ESP_OK) {
    lastAuthMode = String(authModeToString(info.authmode));
  }
}

static unsigned long computeWifiBackoffMs() {
  uint32_t base = WIFI_RETRY_BASE_MS;
  for (uint8_t i = 0; i < wifiFailCount; i++) {
    base = min<uint32_t>(base * 2U, WIFI_RETRY_MAX_MS);
  }
  uint32_t jitter = (uint32_t)random(0, 1000);
  return base + jitter;
}

static bool enqueueEventChecked(const String &json) {
  if (!isValidEventJson(json)) {
    eventInvalidCount++;
    return false;
  }
  if (!queue.push(json)) {
    eventDropCount++;
    return false;
  }
  return true;
}

static bool bssidEquals(const uint8_t *a, const uint8_t *b) {
  for (int i = 0; i < 6; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

static bool shouldEmitAp(const uint8_t *bssid, unsigned long now) {
  int emptyIdx = -1;
  int oldestIdx = 0;
  unsigned long oldestMs = 0;
  for (int i = 0; i < (int)WIFI_AP_MAX_RESULTS; i++) {
    WifiApSeenCache &entry = wifiApCache[i];
    if (!entry.valid) {
      if (emptyIdx < 0) emptyIdx = i;
      continue;
    }
    if (bssidEquals(entry.bssid, bssid)) {
      if (now - entry.last_emit_ms < WIFI_AP_DEDUPE_MS) {
        wifiApDedupeCount++;
        return false;
      }
      entry.last_emit_ms = now;
      return true;
    }
    if (oldestMs == 0 || entry.last_emit_ms < oldestMs) {
      oldestMs = entry.last_emit_ms;
      oldestIdx = i;
    }
  }

  int idx = emptyIdx >= 0 ? emptyIdx : oldestIdx;
  WifiApSeenCache &slot = wifiApCache[idx];
  memcpy(slot.bssid, bssid, 6);
  slot.last_emit_ms = now;
  slot.valid = true;
  return true;
}

static void emitWifiApSeen(const wifi_ap_record_t &ap) {
  unsigned long now = millis();
  if (!shouldEmitAp(ap.bssid, now)) return;

  String data = "{";
  data += jsonKV("ssid", String(reinterpret_cast<const char *>(ap.ssid)));
  data += "," + jsonKV("bssid", bssidToString(ap.bssid));
  data += "," + jsonKV("channel", String(ap.primary), false);
  data += "," + jsonKV("rssi", String(ap.rssi), false);
  data += "," + jsonKV("auth", authModeToString(ap.authmode));
  data += "}";
  if (enqueueEventChecked(buildEvent("wifi.ap_seen", data))) {
    wifiApSeenCount++;
  } else {
    wifiApDropCount++;
  }
}

static String buildEvent(const String &type, const String &dataJson,
                         const String &extraJson) {
  unsigned long ts = (unsigned long)(esp_timer_get_time() / 1000ULL);
  String json = "{";
  json += jsonKV("v", String(EVENT_SCHEMA_VERSION), false);
  json += "," + jsonKV("ts_ms", String(ts), false);
  json += "," + jsonKV("node_id", nodeId);
  json += "," + jsonKV("type", type);
  json += "," + jsonKV("src", nodeId);
  json += "," + jsonKV("seq", String(++eventSeq), false);
  if (extraJson.length() > 0) {
    json += "," + extraJson;
  }
  json += ",\"data\":" + dataJson;
  json += "}";
  return json;
}

static void enqueueEvent(const String &json) {
  (void)enqueueEventChecked(json);
}

static void emitBootEvent() {
  String ip = WiFi.isConnected() ? WiFi.localIP().toString() : "";
  String data = "{";
  data += jsonKV("fw_version", FW_VERSION);
  data += "," + jsonKV("chip_model", ESP.getChipModel());
  data += "," + jsonKV("chip_rev", String(ESP.getChipRevision()));
  data += "," + jsonKV("mac", WiFi.macAddress());
  data += "," + jsonKV("hostname", hostname);
  data += "," + jsonKV("heap_free", String(ESP.getFreeHeap()), false);
  data += "," + jsonKV("sdk_version", ESP.getSdkVersion());
  data += "," + jsonKV("ingest_url", ingestUrl);
  data += "," + jsonMaybeString("ip", ip);
  data += "}";
  enqueueEvent(buildEvent("node.boot", data));
}

static void emitHeartbeat() {
  String ip = WiFi.isConnected() ? WiFi.localIP().toString() : "";
  String data = "{";
  data += jsonKV("uptime_ms", String(millis()), false);
  data += "," + jsonKV("mac", WiFi.macAddress());
  data += "," + jsonKV("hostname", hostname);
  data += "," + jsonKV("wifi_rssi", String(WiFi.RSSI()), false);
  data += "," + jsonMaybeString("ip", ip);
  data += "," + jsonKV("heap_free", String(ESP.getFreeHeap()), false);
  data += "," + jsonKV("queue_depth", String(queue.size()), false);
  data += "," + jsonKV("ble_seen_total", String(bleSeenCount), false);
  data += "}";
  enqueueEvent(buildEvent("node.heartbeat", data));
}

static void emitWifiStatus() {
  String dns0 = ipToString(WiFi.dnsIP(0));
  String dns1 = ipToString(WiFi.dnsIP(1));
  String ip = WiFi.isConnected() ? WiFi.localIP().toString() : "";
  String bssid = WiFi.isConnected() ? WiFi.BSSIDstr() : "";
  int channel = WiFi.channel();
  String data = "{";
  data += jsonKV("connected", jsonBool(WiFi.isConnected()), false);
  data += "," + jsonKV("state", wifiState);
  data += "," + jsonKV("ssid", WiFi.SSID());
  data += "," + jsonMaybeString("bssid", bssid);
  data += "," + jsonKV("channel", String(channel), false);
  data += "," + jsonMaybeString("ip", ip);
  data += "," + jsonKV("mac", WiFi.macAddress());
  data += "," + jsonKV("hostname", hostname);
  data += "," + jsonKV("rssi", String(WiFi.RSSI()), false);
  data += "," + jsonKV("gw", ipToString(WiFi.gatewayIP()));
  data += "," + jsonKV("mask", ipToString(WiFi.subnetMask()));
  data += ",\"dns\":[\"" + dns0 + "\",\"" + dns1 + "\"]";
  if (lastAuthMode.length() > 0) {
    data += "," + jsonKV("auth", lastAuthMode);
  }
  if (lastDisconnectReason >= 0) {
    data += "," + jsonKV("reason", String(lastDisconnectReason), false);
  }
  data += "}";
  enqueueEvent(buildEvent("wifi.status", data));
}

static void emitIngestOk(uint32_t count, unsigned long ms) {
  String data = "{";
  data += jsonKV("ok", "true", false);
  data += "," + jsonKV("batch_count", String(count), false);
  data += "," + jsonKV("ms", String(ms), false);
  data += "}";
  enqueueEvent(buildEvent("ingest.ok", data));
  lastIngestOkEventMs = millis();
}

static void emitIngestErr(const String &err, unsigned long ms) {
  String data = "{";
  data += jsonKV("ok", "false", false);
  data += "," + jsonKV("err", err);
  data += "," + jsonKV("ms", String(ms), false);
  data += "}";
  enqueueEvent(buildEvent("ingest.err", data, jsonKV("err", err)));
  lastIngestErrEventMs = millis();
}

static void emitAnnounce() {
  if (!WiFi.isConnected()) return;
  String dns0 = ipToString(WiFi.dnsIP(0));
  String dns1 = ipToString(WiFi.dnsIP(1));
  String data = "{";
  data += jsonKV("node_id", nodeId);
  data += jsonKV("ip", WiFi.localIP().toString());
  data += "," + jsonKV("mac", WiFi.macAddress());
  data += "," + jsonKV("rssi", String(WiFi.RSSI()), false);
  data += "," + jsonKV("hostname", hostname);
  data += "," + jsonKV("ssid", WiFi.SSID());
  data += "," + jsonKV("gw", ipToString(WiFi.gatewayIP()));
  data += "," + jsonKV("mask", ipToString(WiFi.subnetMask()));
  data += ",\"dns\":[\"" + dns0 + "\",\"" + dns1 + "\"]";
  data += "," + jsonKV("uptime_ms", String(millis()), false);
  data += "," + jsonKV("fw_version", FW_VERSION);
  data += "," + jsonKV("chip", ESP.getChipModel());
  data += "," + jsonKV("http_port", "80", false);
  data += "}";
  enqueueEvent(buildEvent("node.announce", data));
  lastAnnounceMs = millis();
}

static void handlePortalRoot() {
  String page = "<html><body><h2>Strange Lab Node Setup</h2>"
                "<form method='POST' action='/save'>"
                "Wi-Fi SSID:<br><input name='ssid'><br>"
                "Wi-Fi Password:<br><input name='pass' type='password'><br><br>"
                "<button type='submit'>Save</button>"
                "</form></body></html>";
  server.send(200, "text/html", page);
}

static void handlePortalSave() {
  String ssid = server.arg("ssid");
  String pass = server.arg("pass");
  if (ssid.length() == 0) {
    server.send(400, "text/plain", "SSID required");
    return;
  }
  prefs.begin("wifi", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
  server.send(200, "text/plain", "Saved. Rebooting...");
  delay(500);
  ESP.restart();
}

static String maskSecret(const String &value) {
  if (value.length() == 0) return "";
  return "***";
}

static void handleHealth() {
  String out = "{";
  bool ok = WiFi.isConnected() && serverStarted;
  out += "\"ok\":" + jsonBool(ok);
  out += ",\"node_id\":\"" + String(NODE_ID) + "\"";
  out += ",\"uptime_ms\":" + String(millis());
  out += ",\"heap_free\":" + String(ESP.getFreeHeap());

  out += ",\"wifi\":{";
  out += "\"connected\":" + jsonBool(WiFi.isConnected());
  out += ",\"state\":\"" + wifiState + "\"";
  out += ",\"ip\":\"" + ipToString(WiFi.localIP()) + "\"";
  out += ",\"rssi\":" + String(WiFi.RSSI());
  out += ",\"ssid\":\"" + String(WiFi.SSID()) + "\"";
  if (lastDisconnectReason >= 0) {
    out += ",\"reason\":" + String(lastDisconnectReason);
  }
  if (lastAuthMode.length() > 0) {
    out += ",\"auth\":\"" + lastAuthMode + "\"";
  }
  out += "}";

  out += ",\"ingest\":{";
  out += "\"url\":\"" + ingestUrl + "\"";
  out += ",\"ok_count\":" + String(ingestOkCount);
  out += ",\"err_count\":" + String(ingestErrCount);
  out += ",\"last_ok\":"
         + jsonBool(lastIngestOkMs > 0 && lastIngestOkMs >= lastIngestErrMs);
  out += ",\"last_ok_ms\":" + String(lastIngestOkMs);
  out += ",\"last_err_ms\":" + String(lastIngestErrMs);
  out += ",\"last_err\":\"" + jsonEscape(lastIngestErr) + "\"";
  out += "}";

  out += ",\"ble\":{";
  out += "\"enabled\":true";
  out += ",\"seen_count\":" + String(bleSeenCount);
  out += ",\"drop_count\":" + String(bleRingOverwriteCount);
  out += ",\"dedupe_count\":" + String(bleDedupeCount);
  out += "}";

  out += ",\"build\":{";
  out += "\"fw_version\":\"" + String(FW_VERSION) + "\"";
  out += ",\"chip\":\"" + String(ESP.getChipModel()) + "\"";
  out += ",\"rev\":\"" + String(ESP.getChipRevision()) + "\"";
  out += ",\"sdk\":\"" + String(ESP.getSdkVersion()) + "\"";
  out += "}";

  out += ",\"time\":{";
  out += "\"ts_ms\":" + String((unsigned long)(esp_timer_get_time() / 1000ULL));
  out += "}";

  out += "}";
  server.send(200, "application/json", out);
}

static void handleMetrics() {
  String out = "{";
  out += "\"queue_depth\":" + String(queue.size());
  out += ",\"drops\":" + String(eventDropCount);
  out += ",\"ble_seen\":" + String(bleSeenCount);
  out += ",\"ingest_ok\":" + String(ingestOkCount);
  out += ",\"ingest_err\":" + String(ingestErrCount);
  out += ",\"event_queue_depth\":" + String(queue.size());
  out += ",\"event_drop_count\":" + String(eventDropCount);
  out += ",\"event_invalid_count\":" + String(eventInvalidCount);
  out += ",\"ingest_ok_count\":" + String(ingestOkCount);
  out += ",\"ingest_err_count\":" + String(ingestErrCount);
  out += ",\"last_ingest_ok_ms\":" + String(lastIngestOkMs);
  out += ",\"last_ingest_err_ms\":" + String(lastIngestErrMs);
  out += ",\"ble_seen_count\":" + String(bleSeenCount);
  out += ",\"ble_dedupe_count\":" + String(bleDedupeCount);
  out += ",\"ble_ring_overwrite\":" + String(bleRingOverwriteCount);
  out += ",\"ble_scan_restarts\":" + String(bleScanRestartCount);
  out += ",\"ble_scan_stalls\":" + String(bleScanStallCount);
  out += ",\"loop_max_ms\":" + String(loopMaxMs);
  out += ",\"ble_min_heap\":" + String(bleMinHeap);
  out += ",\"wifi_ap_seen_count\":" + String(wifiApSeenCount);
  out += ",\"wifi_ap_dedupe_count\":" + String(wifiApDedupeCount);
  out += ",\"wifi_ap_drop_count\":" + String(wifiApDropCount);
  out += ",\"wifi_ap_scan_count\":" + String(wifiApScanCount);
  out += "}";
  server.send(200, "application/json", out);
}

static void handleConfig() {
  String out = "{";
  out += "\"node_id\":\"" + String(NODE_ID) + "\"";
  out += ",\"fw_version\":\"" + String(FW_VERSION) + "\"";
  out += ",\"ingest_url\":\"" + ingestUrl + "\"";
  out += ",\"wifi_ssid\":\"" + String(WIFI_SSID) + "\"";
  out += ",\"wifi_pass_masked\":\"" + maskSecret(String(WIFI_PASS)) + "\"";
  out += ",\"hostname\":\"" + hostname + "\"";
  out += ",\"event_schema_version\":" + String(EVENT_SCHEMA_VERSION);
  out += ",\"ingest_batch_size\":" + String(INGEST_BATCH_SIZE);
  out += ",\"announce_interval_ms\":" + String(ANNOUNCE_INTERVAL_MS);
  out += ",\"wifi_passive_scan\":" + String(WIFI_PASSIVE_SCAN);
  out += ",\"wifi_scan_interval_ms\":" + String(WIFI_SCAN_INTERVAL_MS);
  out += ",\"wifi_scan_passive_ms\":" + String(WIFI_SCAN_PASSIVE_MS);
  out += ",\"ble_scan_interval\":" + String(BLE_SCAN_INTERVAL_MS);
  out += ",\"ble_scan_window\":" + String(BLE_SCAN_WINDOW_MS);
  out += "}";
  server.send(200, "application/json", out);
}

static void handleWhoami() {
  String dns0 = ipToString(WiFi.dnsIP(0));
  String dns1 = ipToString(WiFi.dnsIP(1));
  String out = "{";
  out += "\"ok\":true";
  out += ",\"node_id\":\"" + String(NODE_ID) + "\"";
  out += ",\"ip\":\"" + ipToString(WiFi.localIP()) + "\"";
  out += ",\"gw\":\"" + ipToString(WiFi.gatewayIP()) + "\"";
  out += ",\"mask\":\"" + ipToString(WiFi.subnetMask()) + "\"";
  out += ",\"dns\":[\"" + dns0 + "\",\"" + dns1 + "\"]";
  out += ",\"rssi\":" + String(WiFi.RSSI());
  out += ",\"mac\":\"" + WiFi.macAddress() + "\"";
  out += ",\"hostname\":\"" + hostname + "\"";
  out += ",\"chip\":\"" + String(ESP.getChipModel()) + "\"";
  out += ",\"fw_version\":\"" + String(FW_VERSION) + "\"";
  out += ",\"wifi_state\":\"" + wifiState + "\"";
  if (lastDisconnectReason >= 0) {
    out += ",\"wifi_reason\":" + String(lastDisconnectReason);
  }
  if (lastAuthMode.length() > 0) {
    out += ",\"wifi_auth\":\"" + lastAuthMode + "\"";
  }
  out += ",\"ts_ms\":" + String((unsigned long)(esp_timer_get_time() / 1000ULL));
  out += ",\"uptime_ms\":" + String(millis());
  out += "}";
  server.send(200, "application/json", out);
}

static void handleWifi() {
  String dns0 = ipToString(WiFi.dnsIP(0));
  String dns1 = ipToString(WiFi.dnsIP(1));
  String out = "{";
  out += "\"ok\":true";
  out += ",\"connected\":" + jsonBool(WiFi.isConnected());
  out += ",\"state\":\"" + wifiState + "\"";
  out += ",\"ssid\":\"" + String(WiFi.SSID()) + "\"";
  out += ",\"ip\":\"" + ipToString(WiFi.localIP()) + "\"";
  out += ",\"gw\":\"" + ipToString(WiFi.gatewayIP()) + "\"";
  out += ",\"mask\":\"" + ipToString(WiFi.subnetMask()) + "\"";
  out += ",\"dns\":[\"" + dns0 + "\",\"" + dns1 + "\"]";
  out += ",\"rssi\":" + String(WiFi.RSSI());
  out += ",\"mac\":\"" + WiFi.macAddress() + "\"";
  if (lastDisconnectReason >= 0) {
    out += ",\"reason\":" + String(lastDisconnectReason);
  }
  if (lastAuthMode.length() > 0) {
    out += ",\"auth\":\"" + lastAuthMode + "\"";
  }
  out += "}";
  server.send(200, "application/json", out);
}

static void handleBleLatest() {
  int limit = server.hasArg("limit") ? server.arg("limit").toInt() : 50;
  if (limit <= 0) limit = 1;
  if (limit > (int)BLE_OBS_CAPACITY) limit = BLE_OBS_CAPACITY;

  String out = "{";
  out += "\"items\":[";
  int emitted = 0;
  for (int i = 0; i < (int)bleRingCount && emitted < limit; i++) {
    size_t idx = (bleRingHead + BLE_OBS_CAPACITY - 1 - i) % BLE_OBS_CAPACITY;
    BleObservation &obs = bleRing[idx];
    if (obs.mac.length() == 0) continue;
    if (emitted > 0) out += ",";
    out += "{";
    out += jsonKV("mac", obs.mac);
    out += "," + jsonKV("rssi", String(obs.rssi), false);
    out += "," + jsonKV("name", obs.name);
    out += "," + jsonKV("mfg_len", String(obs.mfg_len), false);
    out += "," + jsonKV("svc_count", String(obs.svc_count), false);
    out += "," + jsonKV("flags", String(obs.adv_flags), false);
    out += "," + jsonKV("last_seen_ms", String(obs.last_seen_ms), false);
    out += "," + jsonKV("seen_count", String(obs.seen_count), false);
    out += "}";
    emitted++;
  }
  out += "]}";
  server.send(200, "application/json", out);
}

static void handleBleStats() {
  String out = "{";
  out += "\"enabled\":true";
  out += ",\"scanning\":" + jsonBool(bleScan && bleScan->isScanning());
  out += ",\"scan_interval\":" + String(BLE_SCAN_INTERVAL_MS);
  out += ",\"scan_window\":" + String(BLE_SCAN_WINDOW_MS);
  out += ",\"seen_count\":" + String(bleSeenCount);
  out += ",\"dedupe_count\":" + String(bleDedupeCount);
  out += ",\"ring_overwrite\":" + String(bleRingOverwriteCount);
  out += ",\"scan_restarts\":" + String(bleScanRestartCount);
  out += ",\"scan_stalls\":" + String(bleScanStallCount);
  out += ",\"last_result_ms\":" + String(lastBleResultMs);
  out += ",\"last_restart_ms\":" + String(lastBleRestartMs);
  out += "}";
  server.send(200, "application/json", out);
}

static String parseHostFromUrl(const String &url) {
  int scheme = url.indexOf("://");
  int start = scheme >= 0 ? scheme + 3 : 0;
  int slash = url.indexOf('/', start);
  String hostPort = slash >= 0 ? url.substring(start, slash) : url.substring(start);
  int colon = hostPort.indexOf(':');
  if (colon >= 0) {
    return hostPort.substring(0, colon);
  }
  return hostPort;
}

static String baseUrlFromIngest(const String &url) {
  int scheme = url.indexOf("://");
  int start = scheme >= 0 ? scheme + 3 : 0;
  int slash = url.indexOf('/', start);
  if (slash < 0) return url;
  return url.substring(0, slash);
}

static bool bodyFlag(const String &body, const char *key, bool defaultValue) {
  int idx = body.indexOf(String('"') + key + '"');
  if (idx < 0) return defaultValue;
  int colon = body.indexOf(':', idx);
  if (colon < 0) return defaultValue;
  String tail = body.substring(colon + 1);
  tail.toLowerCase();
  if (tail.indexOf("true") >= 0 || tail.indexOf("1") >= 0) return true;
  if (tail.indexOf("false") >= 0 || tail.indexOf("0") >= 0) return false;
  return defaultValue;
}

static void handleProbe() {
  String body = server.hasArg("plain") ? server.arg("plain") : "";
  bool doDns = bodyFlag(body, "dns", true);
  bool doHttpIngest = bodyFlag(body, "http_ingest", true);
  bool doHttpSelf = bodyFlag(body, "http_self", false);
  bool emit = bodyFlag(body, "emit", true);

  String data = "{";
  String dnsData = "{";
  bool hasDns = false;
  String httpData = "{";
  bool hasHttp = false;

  if (doDns) {
    unsigned long start = millis();
    IPAddress resolved;
    String host = parseHostFromUrl(ingestUrl);
    bool ok = WiFi.hostByName(host.c_str(), resolved);
    unsigned long ms = millis() - start;
    data += "\"dns\":{";
    data += "\"host\":\"" + host + "\"";
    data += ",\"ok\":" + jsonBool(ok);
    data += ",\"ms\":" + String(ms);
    data += ",\"ip\":\"" + (ok ? ipToString(resolved) : "") + "\"";
    data += "}";

    dnsData += "\"host\":\"" + host + "\"";
    dnsData += ",\"ok\":" + jsonBool(ok);
    dnsData += ",\"ms\":" + String(ms);
    dnsData += ",\"ip\":\"" + (ok ? ipToString(resolved) : "") + "\"";
    dnsData += "}";
    hasDns = true;
  }

  if (doHttpIngest) {
    if (data.length() > 1) data += ",";
    String base = baseUrlFromIngest(ingestUrl);
    String url = base + "/health";
    HTTPClient http;
    http.setTimeout(PROBE_HTTP_TIMEOUT_MS);
    unsigned long start = millis();
    http.begin(url);
    int code = http.GET();
    http.end();
    unsigned long ms = millis() - start;
    data += "\"http_ingest\":{";
    data += "\"url\":\"" + url + "\"";
    data += ",\"code\":" + String(code);
    data += ",\"ok\":" + jsonBool(code >= 200 && code < 500);
    data += ",\"ms\":" + String(ms);
    data += "}";

    if (hasHttp) httpData += ",";
    httpData += "\"ingest\":{";
    httpData += "\"url\":\"" + url + "\"";
    httpData += ",\"code\":" + String(code);
    httpData += ",\"ok\":" + jsonBool(code >= 200 && code < 500);
    httpData += ",\"ms\":" + String(ms);
    httpData += "}";
    hasHttp = true;
  }

  if (doHttpSelf) {
    if (data.length() > 1) data += ",";
    String url = String("http://") + ipToString(WiFi.localIP()) + "/health";
    HTTPClient http;
    http.setTimeout(PROBE_HTTP_TIMEOUT_MS);
    unsigned long start = millis();
    http.begin(url);
    int code = http.GET();
    http.end();
    unsigned long ms = millis() - start;
    data += "\"http_self\":{";
    data += "\"url\":\"" + url + "\"";
    data += ",\"code\":" + String(code);
    data += ",\"ok\":" + jsonBool(code >= 200 && code < 500);
    data += ",\"ms\":" + String(ms);
    data += "}";

    if (hasHttp) httpData += ",";
    httpData += "\"self\":{";
    httpData += "\"url\":\"" + url + "\"";
    httpData += ",\"code\":" + String(code);
    httpData += ",\"ok\":" + jsonBool(code >= 200 && code < 500);
    httpData += ",\"ms\":" + String(ms);
    httpData += "}";
    hasHttp = true;
  }

  data += "}";

  if (emit) {
    if (hasDns) {
      enqueueEvent(buildEvent("probe.net", dnsData));
    }
    if (hasHttp) {
      enqueueEvent(buildEvent("probe.http", httpData));
    }
  }

  server.send(200, "application/json", data);
}

static void registerStatusRoutes() {
  server.on("/health", HTTP_GET, handleHealth);
  server.on("/metrics", HTTP_GET, handleMetrics);
  server.on("/config", HTTP_GET, handleConfig);
  server.on("/probe", HTTP_POST, handleProbe);
  server.on("/whoami", HTTP_GET, handleWhoami);
  server.on("/wifi", HTTP_GET, handleWifi);
  server.on("/ble/latest", HTTP_GET, handleBleLatest);
  server.on("/ble/stats", HTTP_GET, handleBleStats);
}

static String sanitizeHostname(const String &raw) {
  String out;
  out.reserve(raw.length());
  for (size_t i = 0; i < raw.length(); i++) {
    char c = raw[i];
    if ((c >= 'A' && c <= 'Z')) c = char(c + 32);
    bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
    if (ok) out += c;
  }
  if (out.length() == 0) out = "node";
  return out;
}

static void ensureMdns() {
  if (!WiFi.isConnected()) return;
  if (mdnsStarted || mdnsFailed) return;
  if (MDNS.begin(hostname.c_str())) {
    MDNS.addService("http", "tcp", 80);
    MDNS.addServiceTxt("http", "tcp", "node_id", nodeId);
    MDNS.addServiceTxt("http", "tcp", "fw_version", FW_VERSION);
    MDNS.addServiceTxt("http", "tcp", "chip", ESP.getChipModel());
    mdnsStarted = true;
  } else {
    mdnsFailed = true;
  }
}

static void handleWifiEvent(WiFiEvent_t event, WiFiEventInfo_t info) {
#if defined(ARDUINO_EVENT_WIFI_STA_DISCONNECTED)
  const WiFiEvent_t kStaDisconnected = ARDUINO_EVENT_WIFI_STA_DISCONNECTED;
#else
  const WiFiEvent_t kStaDisconnected = (WiFiEvent_t)SYSTEM_EVENT_STA_DISCONNECTED;
#endif
#if defined(ARDUINO_EVENT_WIFI_STA_GOT_IP)
  const WiFiEvent_t kStaGotIp = ARDUINO_EVENT_WIFI_STA_GOT_IP;
#else
  const WiFiEvent_t kStaGotIp = (WiFiEvent_t)SYSTEM_EVENT_STA_GOT_IP;
#endif
#if defined(ARDUINO_EVENT_WIFI_STA_CONNECTED)
  const WiFiEvent_t kStaConnected = ARDUINO_EVENT_WIFI_STA_CONNECTED;
#else
  const WiFiEvent_t kStaConnected = (WiFiEvent_t)SYSTEM_EVENT_STA_CONNECTED;
#endif
#if defined(ARDUINO_EVENT_WIFI_SCAN_DONE)
  const WiFiEvent_t kScanDone = ARDUINO_EVENT_WIFI_SCAN_DONE;
#else
  const WiFiEvent_t kScanDone = (WiFiEvent_t)SYSTEM_EVENT_SCAN_DONE;
#endif

  if (event == kStaDisconnected) {
    lastDisconnectReason = info.wifi_sta_disconnected.reason;
    wifiState = "backoff";
    wifiFailCount = min<uint8_t>(wifiFailCount + 1, 6);
    nextWifiAttemptMs = millis() + computeWifiBackoffMs();
    wifiConnectStartMs = 0;
    emitWifiStatus();
    return;
  }

  if (event == kStaGotIp) {
    wifiState = "connected";
    wifiFailCount = 0;
    refreshAuthMode();
    emitWifiStatus();
    emitAnnounce();
    return;
  }

  if (event == kStaConnected) {
    wifiState = "connecting";
    emitWifiStatus();
    return;
  }

  if (event == kScanDone) {
    handleWifiScanDone();
  }
}

static void startCaptivePortal() {
  WiFi.mode(WIFI_AP);
  String apName = "StrangeLab-Setup-" + String((uint32_t)ESP.getEfuseMac(), HEX);
  WiFi.softAP(apName.c_str());
  server.on("/", HTTP_GET, handlePortalRoot);
  server.on("/save", HTTP_POST, handlePortalSave);
  if (!serverStarted) {
    server.begin();
    serverStarted = true;
  }
  portalActive = true;
}

static void applyWifiConfig() {
#if WIFI_FORCE_WPA2
  wifi_config_t conf = {};
  strncpy(reinterpret_cast<char *>(conf.sta.ssid), runtimeSsid.c_str(), sizeof(conf.sta.ssid) - 1);
  strncpy(reinterpret_cast<char *>(conf.sta.password), runtimePass.c_str(),
          sizeof(conf.sta.password) - 1);
  conf.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
  esp_wifi_set_config(WIFI_IF_STA, &conf);
#endif
}

static void loadRuntimeCreds() {
  prefs.begin("wifi", true);
  runtimeSsid = prefs.getString("ssid", "");
  runtimePass = prefs.getString("pass", "");
  prefs.end();
}

static void ensureWiFi() {
  if (WiFi.isConnected()) return;
  if (runtimeSsid.length() == 0) {
    if (!portalActive) startCaptivePortal();
    return;
  }
  if (millis() < nextWifiAttemptMs) {
    if (wifiState != "backoff") {
      wifiState = "backoff";
      emitWifiStatus();
    }
    return;
  }
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  applyWifiConfig();
  WiFi.setAutoReconnect(true);
  WiFi.begin(runtimeSsid.c_str(), runtimePass.c_str());
  wifiState = "connecting";
  wifiConnectStartMs = millis();
  emitWifiStatus();
}

static void startWifiScanPassive() {
#if WIFI_PASSIVE_SCAN
  if (!WiFi.isConnected()) return;
  if (wifiScanInProgress) return;
  if (millis() - lastWifiScanMs < WIFI_SCAN_INTERVAL_MS) return;
  wifi_scan_config_t config = {};
  config.show_hidden = true;
  config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
  config.scan_time.passive = WIFI_SCAN_PASSIVE_MS;
  if (esp_wifi_scan_start(&config, false) == ESP_OK) {
    wifiScanInProgress = true;
    lastWifiScanMs = millis();
    wifiApScanCount++;
  }
#endif
}

static void handleWifiScanDone() {
  wifiScanInProgress = false;
  lastWifiScanCompleteMs = millis();
  uint16_t apCount = 0;
  if (esp_wifi_scan_get_ap_num(&apCount) != ESP_OK) return;
  if (apCount == 0) return;
  uint16_t fetch = min<uint16_t>(apCount, WIFI_AP_MAX_RESULTS);
  wifi_ap_record_t *records =
      reinterpret_cast<wifi_ap_record_t *>(malloc(sizeof(wifi_ap_record_t) * fetch));
  if (!records) return;
  if (esp_wifi_scan_get_ap_records(&fetch, records) != ESP_OK) {
    free(records);
    return;
  }
  uint16_t emitted = 0;
  for (uint16_t i = 0; i < fetch && emitted < WIFI_AP_EMIT_PER_SCAN; i++) {
    emitWifiApSeen(records[i]);
    emitted++;
  }
  free(records);
}

static unsigned long computeBackoffMs() {
  uint32_t base = 1000U;
  for (uint8_t i = 0; i < failCount; i++) {
    base = min<uint32_t>(base * 2U, 30000U);
  }
  uint32_t jitter = (uint32_t)random(0, 1000);
  return base + jitter;
}

static void logBatchIfNeeded(size_t batch) {
  for (size_t i = 0; i < batch; i++) {
    EventEntry &entry = queue.at(i);
    if (!entry.logged) {
      Serial.println(entry.json);
      entry.logged = true;
    }
  }
}

static void trySendQueued() {
  if (queue.empty()) return;
  if (millis() < nextSendAtMs) return;

  if (!WiFi.isConnected()) {
    logBatchIfNeeded(1);
    nextSendAtMs = millis() + computeBackoffMs();
    failCount = min<uint8_t>(failCount + 1, 6);
    return;
  }

  size_t batch = min(queue.size(), (size_t)INGEST_BATCH_SIZE);
  String payload;
  if (batch <= 1) {
    payload = queue.front().json;
  } else {
    payload = "[";
    for (size_t i = 0; i < batch; i++) {
      if (i > 0) payload += ",";
      payload += queue.at(i).json;
    }
    payload += "]";
  }

  HTTPClient http;
  http.setTimeout(INGEST_TIMEOUT_MS);
  http.begin(ingestUrl);
  http.addHeader("Content-Type", "application/json");
  unsigned long start = millis();
  int code = http.POST(payload);
  unsigned long ms = millis() - start;
  bool ok = (code >= 200 && code < 300);
  http.end();

  if (ok) {
    for (size_t i = 0; i < batch; i++) {
      queue.pop();
    }
    failCount = 0;
    ingestOkCount++;
    markIngestOk();
    if (lastIngestErr.length() > 0 || (millis() - lastIngestOkEventMs) > 60000) {
      emitIngestOk((uint32_t)batch, ms);
    }
  } else {
    logBatchIfNeeded(batch);
    failCount = min<uint8_t>(failCount + 1, 6);
    nextSendAtMs = millis() + computeBackoffMs();
    ingestErrCount++;
    String err = String(code);
    markIngestErr(err);
    if (lastIngestErr.length() == 0 || lastIngestErr != err ||
        (millis() - lastIngestErrEventMs) > 60000) {
      emitIngestErr(err, ms);
    }
  }
}

static bool bleMatches(const BleObservation &obs, const String &mac, uint8_t advFlags) {
  if (obs.mac != mac) return false;
  if (obs.adv_flags != advFlags) return false;
  return true;
}

static void recordBleObservation(const String &mac, const String &name, int rssi,
                                 uint8_t svcCount, uint8_t mfgLen, uint8_t advFlags) {
  unsigned long now = millis();
  for (size_t i = 0; i < bleRingCount; i++) {
    size_t idx = (bleRingHead + BLE_OBS_CAPACITY - 1 - i) % BLE_OBS_CAPACITY;
    BleObservation &obs = bleRing[idx];
    if (obs.mac.length() == 0) continue;
    if (bleMatches(obs, mac, advFlags)) {
      if (now - obs.last_seen_ms <= BLE_DEDUPE_MS) {
        obs.rssi = rssi;
        obs.last_seen_ms = now;
        obs.seen_count++;
        bleDedupeCount++;
        return;
      }
      obs.rssi = rssi;
      obs.name = name;
      obs.svc_count = svcCount;
      obs.mfg_len = mfgLen;
      obs.adv_flags = advFlags;
      obs.last_seen_ms = now;
      obs.seen_count++;
      return;
    }
  }

  BleObservation &slot = bleRing[bleRingHead];
  if (bleRingCount == BLE_OBS_CAPACITY) {
    bleRingOverwriteCount++;
  } else {
    bleRingCount++;
  }
  slot.mac = mac;
  slot.name = name;
  slot.rssi = rssi;
  slot.mfg_len = mfgLen;
  slot.svc_count = svcCount;
  slot.adv_flags = advFlags;
  slot.last_seen_ms = now;
  slot.seen_count = 1;
  bleRingHead = (bleRingHead + 1) % BLE_OBS_CAPACITY;
}

class AdvertisedCallback : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice *device) override {
    unsigned long now = millis();
    lastBleResultMs = now;
    if (now - bleSecondStart >= 1000) {
      bleSecondStart = now;
      bleCountThisSecond = 0;
    }
    if (bleCountThisSecond >= BLE_MAX_PER_SECOND) {
      return;
    }
    bleCountThisSecond++;
    bleSeenCount++;

    String addr = device->getAddress().toString().c_str();
    addr.toLowerCase();
    String addrType = "unknown";
    switch (device->getAddressType()) {
      case BLE_ADDR_PUBLIC: addrType = "public"; break;
      case BLE_ADDR_RANDOM: addrType = "random"; break;
      default: break;
    }

    String name = device->getName().c_str();
    uint8_t advFlags = device->getAdvFlags();
    uint8_t svcCount = device->getServiceUUIDCount();
    uint8_t mfgLen = (uint8_t)device->getManufacturerData().length();

    recordBleObservation(addr, name, device->getRSSI(), svcCount, mfgLen, advFlags);

    String data = "{";
    data += jsonKV("addr", addr);
    data += "," + jsonKV("rssi", String(device->getRSSI()), false);
    data += "," + jsonKV("addr_type", addrType);
    data += "," + jsonKV("flags", String(advFlags), false);
    data += "}";

    String extra = jsonKV("mac", addr) + "," +
                   jsonKV("rssi", String(device->getRSSI()), false);
    enqueueEvent(buildEvent("ble.seen", data, extra));
  }
};

static AdvertisedCallback advCallback;

static void startBLE() {
  NimBLEDevice::init("");
  bleScan = NimBLEDevice::getScan();
  bleScan->setAdvertisedDeviceCallbacks(&advCallback, false);
  bleScan->setActiveScan(false);
  bleScan->setInterval(BLE_SCAN_INTERVAL_MS);
  bleScan->setWindow(BLE_SCAN_WINDOW_MS);
  bleScan->start(0, nullptr, false);
  lastBleRestartMs = millis();
  bleScanRestartCount++;
}

static void ensureBleScan() {
  if (!bleScan) return;
  if (!bleScan->isScanning()) {
    bleScan->start(0, nullptr, false);
    lastBleRestartMs = millis();
    bleScanRestartCount++;
  } else if (lastBleResultMs > 0 && (millis() - lastBleResultMs) > BLE_SCAN_RESTART_MS) {
    bleScan->stop();
    bleScan->start(0, nullptr, false);
    lastBleRestartMs = millis();
    bleScanStallCount++;
  }
}

void setup() {
  Serial.begin(115200);
  delay(100);

  randomSeed((uint32_t)esp_random());
  registerStatusRoutes();
  WiFi.onEvent(handleWifiEvent);
  String compileNodeId = String(NODE_ID);
  nodeId = compileNodeId.length() > 0 ? compileNodeId : String(kDefaultNodeId);
  hostname = sanitizeHostname(nodeId);
  String compileIngest = String(INGEST_URL);
  ingestUrl = compileIngest.length() > 0 ? compileIngest : String(kDefaultIngestUrl);
  loadRuntimeCreds();
  if (String(WIFI_SSID).length() > 0) {
    runtimeSsid = WIFI_SSID;
    runtimePass = WIFI_PASS;
  }

#if WIFI_RESET_ON_BOOT
  WiFi.disconnect(true, true);
  delay(500);
#endif

  if (runtimeSsid.length() == 0) {
    startCaptivePortal();
  } else {
    WiFi.mode(WIFI_STA);
    WiFi.setHostname(hostname.c_str());
    WiFi.setSleep(false);
    applyWifiConfig();
    WiFi.setAutoReconnect(true);
    WiFi.begin(runtimeSsid.c_str(), runtimePass.c_str());
    wifiState = "connecting";
    emitWifiStatus();
  }

  if (!serverStarted) {
    server.begin();
    serverStarted = true;
  }

  startBLE();
  emitBootEvent();
}

void loop() {
  unsigned long loopStart = millis();

  if (serverStarted) {
    server.handleClient();
  }

  ensureWiFi();
  ensureBleScan();
  ensureMdns();
  startWifiScanPassive();

  if (wifiState == "connecting" && !WiFi.isConnected() &&
      wifiConnectStartMs > 0 &&
      (millis() - wifiConnectStartMs) > WIFI_CONNECT_TIMEOUT_MS) {
    WiFi.disconnect();
    wifiFailCount = min<uint8_t>(wifiFailCount + 1, 6);
    nextWifiAttemptMs = millis() + computeWifiBackoffMs();
    wifiState = "backoff";
    wifiConnectStartMs = 0;
    emitWifiStatus();
  }

  bool wifiConnected = WiFi.isConnected();
  String ipStr = wifiConnected ? WiFi.localIP().toString() : "";
  bool ipChanged = (ipStr != lastIpStr);
  if (wifiConnected != lastWifiConnected || (wifiConnected && ipChanged)) {
    lastWifiConnected = wifiConnected;
    lastIpStr = ipStr;
    if (wifiConnected) {
      emitWifiStatus();
      emitAnnounce();
    }
  }

  unsigned long now = millis();
  if (now - lastHeartbeatMs >= 10000) {
    lastHeartbeatMs = now;
    emitHeartbeat();
  }

  if (wifiConnected && (now - lastAnnounceMs >= ANNOUNCE_INTERVAL_MS)) {
    emitAnnounce();
  }

  trySendQueued();

  uint32_t heap = ESP.getFreeHeap();
  if (bleMinHeap == 0 || heap < bleMinHeap) {
    bleMinHeap = heap;
  }

  unsigned long loopMs = millis() - loopStart;
  if (loopMs > loopMaxMs) loopMaxMs = loopMs;

  delay(1);
}
