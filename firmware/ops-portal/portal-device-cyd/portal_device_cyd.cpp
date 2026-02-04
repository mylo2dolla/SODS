#include "portal_device_cyd.h"

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <WebSocketsClient.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>

#include "portal_core.h"

#ifndef WIFI_SSID
#define WIFI_SSID ""
#endif

#ifndef WIFI_PASS
#define WIFI_PASS ""
#endif

#ifndef SODS_BASE_URL
#define SODS_BASE_URL ""
#endif

#ifndef PORTAL_ROTATION
#define PORTAL_ROTATION 1
#endif

#define TOUCH_CS 33
#define TOUCH_IRQ 36

static TFT_eSPI tft = TFT_eSPI();
static XPT2046_Touchscreen touch(TOUCH_CS, TOUCH_IRQ);
static PortalCore core;

static String sodsBaseUrl;
static String wifiSsid;
static String wifiPass;

static unsigned long lastPollMs = 0;
static unsigned long pollIntervalMs = 1200;
static unsigned long lastToolsMs = 0;
static unsigned long toolsIntervalMs = 8000;
static unsigned long lastRenderMs = 0;
static bool wifiOk = false;
static unsigned long lastWifiOkMs = 0;
static String lastWifiErr = "";
static bool stationOk = false;
static unsigned long lastStationOkMs = 0;

static WebSocketsClient wsClient;
static bool wsConnected = false;
static unsigned long lastWsAttemptMs = 0;
static unsigned long wsBackoffMs = 2000;
static String wsHost = "";
static int wsPort = 80;
static String wsPath = "/ws/frames";
static unsigned long lastFrameMs = 0;
static const char *mockStatusJson = R"json(
{
  "station": {
    "ok": false,
    "uptime_ms": 0,
    "last_ingest_ms": 0,
    "last_error": "mock",
    "pi_logger": "mock",
    "nodes_total": 6,
    "nodes_online": 3,
    "tools": 3
  },
  "logger": { "ok": false, "status": "offline" }
}
)json";

static const char *mockToolsJson = R"json(
{
  "tools": [
    { "name": "net.wifi_scan", "kind": "passive" },
    { "name": "net.arp", "kind": "passive" },
    { "name": "camera.viewer", "kind": "passive" }
  ]
}
)json";

static float readFloat(const JsonVariant &v, float fallback) {
  if (v.is<float>()) return v.as<float>();
  if (v.is<double>()) return (float)v.as<double>();
  if (v.is<int>()) return (float)v.as<int>();
  if (v.is<const char*>()) return atof(v.as<const char*>());
  return fallback;
}

static float hash01(const String &value, float offset) {
  uint32_t hash = 2166136261u;
  for (size_t i = 0; i < value.length(); i++) {
    hash ^= (uint8_t)value[i];
    hash *= 16777619u;
  }
  uint32_t mix = hash ^ (uint32_t)(offset * 1000.0f);
  return (mix % 1000) / 1000.0f;
}

static bool parseBaseUrl(const String &baseUrl, String &hostOut, int &portOut) {
  if (baseUrl.length() == 0) return false;
  String work = baseUrl;
  if (work.startsWith("http://")) {
    work = work.substring(7);
  } else if (work.startsWith("https://")) {
    work = work.substring(8);
  }
  int slash = work.indexOf('/');
  if (slash >= 0) work = work.substring(0, slash);
  int colon = work.indexOf(':');
  if (colon >= 0) {
    hostOut = work.substring(0, colon);
    portOut = work.substring(colon + 1).toInt();
  } else {
    hostOut = work;
    portOut = 80;
  }
  return hostOut.length() > 0;
}

static void updateOrientation() {
  int w = tft.width();
  int h = tft.height();
  core.setScreen(w, h);
  PortalMode mode = (w >= h) ? PortalMode::Utility : PortalMode::Watch;
  core.setMode(mode);
  core.state().modeName = (mode == PortalMode::Utility) ? "utility" : "watch";
}

static void sendCommand(const ButtonAction &action) {
  if (sodsBaseUrl.length() == 0) return;
  HTTPClient http;
  String url = sodsBaseUrl + "/api/tool/run";
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  String payload = "{";
  payload += "\"name\":\"" + action.cmd + "\"";
  if (action.argsJson.length() > 0) {
    payload += ",\"input\":" + action.argsJson;
  } else {
    payload += ",\"input\":{}";
  }
  payload += "}";
  http.POST(payload);
  http.end();
}

static void handleTouch() {
  if (!touch.touched()) return;
  TS_Point p = touch.getPoint();
  int x = map(p.y, 200, 3800, 0, tft.width());
  int y = map(p.x, 200, 3800, 0, tft.height());

  unsigned long start = millis();
  while (touch.touched()) {
    delay(8);
    if (millis() - start > 700) break;
  }

  if (core.popupActive()) {
    int actionIdx = core.popupHit(x, y);
    int buttonIdx = core.popupButtonIdx();
    if (actionIdx >= 0 && buttonIdx >= 0) {
      auto &state = core.state();
      if (buttonIdx < (int)state.buttons.size()) {
        auto &actions = state.buttons[buttonIdx].actions;
        if (actionIdx < (int)actions.size()) {
          sendCommand(actions[actionIdx]);
        }
      }
    }
    core.dismissPopup();
    return;
  }

  if (core.mode() == PortalMode::Watch) {
    core.toggleOverlay(millis());
    return;
  }

  int idx = -1;
  if (!core.hitButton(x, y, idx)) return;
  auto &state = core.state();
  if (idx < 0 || idx >= (int)state.buttons.size()) return;
  ButtonState &b = state.buttons[idx];
  if (!b.enabled) return;

  if (b.actions.size() > 1) {
    core.showPopup(idx, millis());
    return;
  }

  if (!b.actions.empty()) {
    sendCommand(b.actions[0]);
  }
}

static void applyFrames(JsonArray frames) {
  PortalState &state = core.state();
  std::vector<VizBin> nextBins;
  for (JsonVariant fv : frames) {
    VizBin bin;
    String id = String((const char*)(fv["device_id"] | fv["node_id"] | fv["id"] | "frame"));
    bin.id = id;
    bin.x = readFloat(fv["x"], 0.1f + hash01(id, 0.2f) * 0.8f);
    bin.y = readFloat(fv["y"], 0.1f + hash01(id, 0.6f) * 0.8f);
    JsonObject color = fv["color"];
    bin.hue = readFloat(color["h"], readFloat(fv["h"], hash01(id, 0.9f) * 360.0f));
    bin.sat = readFloat(color["s"], readFloat(fv["s"], 0.7f));
    bin.light = readFloat(color["l"], readFloat(fv["l"], 0.5f));
    float persistence = readFloat(fv["persistence"], 0.4f);
    float confidence = readFloat(fv["confidence"], 0.6f);
    float rssi = readFloat(fv["rssi"], -70.0f);
    float rssiNorm = (rssi + 100.0f) / 70.0f;
    rssiNorm = max(0.0f, min(1.0f, rssiNorm));
    bin.level = max(0.2f, min(1.0f, persistence + confidence * 0.3f + rssiNorm * 0.2f));
    bin.glow = readFloat(fv["glow"], confidence);
    nextBins.push_back(bin);
    if (nextBins.size() >= 16) break;
  }
  if (!nextBins.empty()) {
    state.bins = nextBins;
  } else {
    for (auto &bin : state.bins) {
      bin.level *= 0.92f;
      bin.glow *= 0.85f;
    }
  }
}

static void parseStatus(const String &json) {
  DynamicJsonDocument doc(8192);
  DeserializationError err = deserializeJson(doc, json);
  if (err) return;
  JsonObject root = doc.as<JsonObject>();

  PortalState &state = core.state();

  JsonObject station = root["station"];
  if (!station.isNull()) {
    stationOk = station["ok"] | false;
    state.connOk = stationOk && wsConnected;
    state.connLastOkMs = station["last_ingest_ms"] | 0;
    state.connErr = String((const char*)(station["last_error"] | ""));
    state.nodesTotal = station["nodes_total"] | 0;
    state.nodesOnline = station["nodes_online"] | 0;
    state.ingestLastOkMs = station["last_ingest_ms"] | 0;
    state.ingestOkRate = (state.ingestLastOkMs > 0 && (millis() - lastStationOkMs) < 60 * 1000) ? 1.0f : 0.0f;
    state.ingestErrRate = 0.0f;
    state.nodesLastAnnounceMs = state.ingestLastOkMs;
  }
}

static void parseTools(const String &json) {
  DynamicJsonDocument doc(8192);
  DeserializationError err = deserializeJson(doc, json);
  if (err) return;
  JsonObject root = doc.as<JsonObject>();
  JsonArray tools = root["tools"].as<JsonArray>();
  if (tools.isNull()) tools = root["items"].as<JsonArray>();
  if (tools.isNull()) return;

  PortalState &state = core.state();
  state.buttons.clear();
  for (JsonVariant v : tools) {
    ButtonState b;
    b.id = String((const char*)(v["name"] | ""));
    b.label = b.id;
    int dot = b.label.lastIndexOf('.');
    if (dot >= 0 && dot + 1 < b.label.length()) {
      b.label = b.label.substring(dot + 1);
    }
    b.kind = String((const char*)(v["kind"] | ""));
    b.enabled = b.kind == "passive";
    b.glow = 0.2f;
    ButtonAction a;
    a.id = b.id;
    a.label = b.id;
    a.cmd = b.id;
    b.actions.push_back(a);
    state.buttons.push_back(b);
    if (state.buttons.size() >= 6) break;
  }
}

static void pollStatus() {
  if (sodsBaseUrl.length() == 0) {
    parseStatus(String(mockStatusJson));
    core.state().connOk = false;
    return;
  }
  HTTPClient http;
  String url = sodsBaseUrl + "/api/status";
  http.begin(url);
  int code = http.GET();
  if (code >= 200 && code < 300) {
    String body = http.getString();
    parseStatus(body);
    stationOk = true;
    lastStationOkMs = millis();
  } else {
    stationOk = false;
  }
  http.end();
}

static void pollTools() {
  if (sodsBaseUrl.length() == 0) {
    parseTools(String(mockToolsJson));
    return;
  }
  HTTPClient http;
  String url = sodsBaseUrl + "/api/tools";
  http.begin(url);
  int code = http.GET();
  if (code >= 200 && code < 300) {
    String body = http.getString();
    parseTools(body);
  }
  http.end();
}

static void handleWsEvent(WStype_t type, uint8_t *payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      wsConnected = false;
      break;
    case WStype_CONNECTED:
      wsConnected = true;
      break;
    case WStype_TEXT: {
      DynamicJsonDocument doc(8192);
      DeserializationError err = deserializeJson(doc, payload, length);
      if (err) break;
      JsonArray frames = doc["frames"].as<JsonArray>();
      if (!frames.isNull()) {
        applyFrames(frames);
        lastFrameMs = millis();
      }
      break;
    }
    default:
      break;
  }
}

static void ensureWebSocket(unsigned long now) {
  if (!wifiOk || sodsBaseUrl.length() == 0) return;
  if (wsConnected) return;
  if (now - lastWsAttemptMs < wsBackoffMs) return;
  lastWsAttemptMs = now;
  if (!parseBaseUrl(sodsBaseUrl, wsHost, wsPort)) return;
  wsPath = "/ws/frames";
  wsClient.begin(wsHost.c_str(), wsPort, wsPath.c_str());
  wsClient.onEvent(handleWsEvent);
  wsClient.setReconnectInterval(2000);
}

static void ensureWiFi() {
  if (WiFi.isConnected()) {
    wifiOk = true;
    lastWifiOkMs = millis();
    return;
  }
  if (wifiSsid.length() == 0 || wifiPass.length() == 0) {
    wifiOk = false;
    lastWifiErr = "wifi creds missing";
    return;
  }
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
}

void PortalDeviceCYD::setup() {
  Serial.begin(115200);
  delay(200);

  wifiSsid = WIFI_SSID;
  wifiPass = WIFI_PASS;
  sodsBaseUrl = SODS_BASE_URL;

  tft.init();
  tft.setRotation(PORTAL_ROTATION);
  if (TFT_BL >= 0) {
    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, TFT_BACKLIGHT_ON);
  }

  touch.begin();
  touch.setRotation(PORTAL_ROTATION);

  core.begin(&tft);
  updateOrientation();
  core.render(millis());

  tft.setTextColor(TFT_RED, TFT_BLACK);
  tft.setCursor(6, 6);
  tft.print("SODS Ops Portal boot");

  ensureWiFi();
  if (parseBaseUrl(sodsBaseUrl, wsHost, wsPort)) {
    wsClient.onEvent(handleWsEvent);
  }
}

void PortalDeviceCYD::loop() {
  unsigned long now = millis();
  if (now - lastPollMs > pollIntervalMs) {
    lastPollMs = now;
    ensureWiFi();
    if (WiFi.isConnected()) {
      pollStatus();
    } else {
      core.state().connErr = lastWifiErr;
    }
    core.updateTrails();
  }
  if (now - lastToolsMs > toolsIntervalMs) {
    lastToolsMs = now;
    if (WiFi.isConnected()) {
      pollTools();
    }
  }
  if (WiFi.isConnected()) {
    ensureWebSocket(now);
    wsClient.loop();
  }
  core.state().connOk = stationOk && wsConnected;
  if (lastFrameMs > 0 && now - lastFrameMs > 2000) {
    for (auto &bin : core.state().bins) {
      bin.level *= 0.95f;
      bin.glow *= 0.9f;
    }
  }
  if (now - lastRenderMs > 120) {
    lastRenderMs = now;
    updateOrientation();
    core.render(now);
  }
  handleTouch();
  delay(5);
}
