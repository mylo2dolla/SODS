#include "portal_device_cyd.h"

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
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
static unsigned long lastRenderMs = 0;
static bool wifiOk = false;
static unsigned long lastWifiOkMs = 0;
static String lastWifiErr = "";
static const char *mockStateJson = R"json(
{
  "connection": { "ok": false, "error": "mock" },
  "mode": { "name": "mock", "since_ms": 0 },
  "nodes": { "total": 6, "online": 3, "last_announce_ms": 0 },
  "ingest": { "ok_rate": 4.2, "err_rate": 0.3, "last_ok_ms": 0, "last_err_ms": 0 },
  "buttons": [
    { "id": "sync", "label": "Sync", "kind": "action", "enabled": true, "glow_level": 0.6, "actions": ["sync"] },
    { "id": "scan", "label": "Scan", "kind": "action", "enabled": true, "glow_level": 0.3, "actions": ["scan"] },
    { "id": "tools", "label": "Tools", "kind": "menu", "enabled": true, "glow_level": 0.2, "actions": [
      { "id": "spectrum", "label": "Spectrum", "cmd": "spectrum" },
      { "id": "rebuild", "label": "Rebuild", "cmd": "rebuild" }
    ]}
  ],
  "visualizer": { "bins": [
    { "id": "a", "x": 0.2, "y": 0.4, "level": 0.6, "h": 10, "s": 0.8, "l": 0.55, "glow": 0.7 },
    { "id": "b", "x": 0.6, "y": 0.3, "level": 0.5, "h": 350, "s": 0.7, "l": 0.5, "glow": 0.5 },
    { "id": "c", "x": 0.4, "y": 0.7, "level": 0.7, "h": 40, "s": 0.9, "l": 0.6, "glow": 0.9 }
  ]}
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

static void updateOrientation() {
  int w = tft.width();
  int h = tft.height();
  core.setScreen(w, h);
  PortalMode mode = (w >= h) ? PortalMode::Utility : PortalMode::Watch;
  core.setMode(mode);
}

static void sendCommand(const ButtonAction &action) {
  if (sodsBaseUrl.length() == 0) return;
  HTTPClient http;
  String url = sodsBaseUrl + "/opsportal/cmd";
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  String payload = "{";
  payload += "\"cmd\":\"" + action.cmd + "\"";
  if (action.argsJson.length() > 0) {
    payload += ",\"args\":" + action.argsJson;
  } else {
    payload += ",\"args\":{}";
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

static void parseState(const String &json) {
  DynamicJsonDocument doc(8192);
  DeserializationError err = deserializeJson(doc, json);
  if (err) return;
  JsonObject root = doc.as<JsonObject>();

  PortalState &state = core.state();

  JsonObject conn = root["connection"];
  if (!conn.isNull()) {
    state.connOk = conn["ok"] | false;
    state.connLastOkMs = conn["last_ok_ms"] | 0;
    state.connErr = String((const char*)(conn["error"] | ""));
  }
  JsonObject mode = root["mode"];
  if (!mode.isNull()) {
    state.modeName = String((const char*)(mode["name"] | ""));
    state.modeSinceMs = mode["since_ms"] | 0;
  }
  JsonObject nodes = root["nodes"];
  if (!nodes.isNull()) {
    state.nodesTotal = nodes["total"] | 0;
    state.nodesOnline = nodes["online"] | 0;
    state.nodesLastAnnounceMs = nodes["last_announce_ms"] | 0;
  }
  JsonObject ingest = root["ingest"];
  if (!ingest.isNull()) {
    state.ingestOkRate = readFloat(ingest["ok_rate"], 0);
    state.ingestErrRate = readFloat(ingest["err_rate"], 0);
    state.ingestLastOkMs = ingest["last_ok_ms"] | 0;
    state.ingestLastErrMs = ingest["last_err_ms"] | 0;
  }
  state.buttons.clear();
  JsonArray buttons = root["buttons"].as<JsonArray>();
  for (JsonVariant v : buttons) {
    ButtonState b;
    b.id = String((const char*)(v["id"] | ""));
    b.label = String((const char*)(v["label"] | ""));
    b.kind = String((const char*)(v["kind"] | ""));
    b.enabled = v["enabled"] | true;
    b.glow = readFloat(v["glow_level"], 0.0f);
    JsonArray actions = v["actions"].as<JsonArray>();
    for (JsonVariant av : actions) {
      ButtonAction a;
      if (av.is<const char*>()) {
        a.id = String((const char*)av.as<const char*>());
        a.label = a.id;
        a.cmd = a.id;
      } else {
        a.id = String((const char*)(av["id"] | ""));
        a.label = String((const char*)(av["label"] | a.id.c_str()));
        a.cmd = String((const char*)(av["cmd"] | a.id.c_str()));
        if (av.containsKey("args")) {
          String args; serializeJson(av["args"], args); a.argsJson = args;
        }
      }
      b.actions.push_back(a);
    }
    state.buttons.push_back(b);
  }

  state.bins.clear();
  JsonArray frames = root["frames"].as<JsonArray>();
  if (!frames.isNull() && frames.size() > 0) {
    for (JsonVariant fv : frames) {
      VizBin bin;
      String id = String((const char*)(fv["device_id"] | fv["node_id"] | "frame"));
      bin.id = id;
      bin.x = readFloat(fv["x"], 0.1f + hash01(id, 0.2f) * 0.8f);
      bin.y = readFloat(fv["y"], 0.1f + hash01(id, 0.6f) * 0.8f);
      JsonObject color = fv["color"];
      bin.hue = readFloat(color["h"], 0.0f);
      bin.sat = readFloat(color["s"], 0.7f);
      bin.light = readFloat(color["l"], 0.5f);
      float persistence = readFloat(fv["persistence"], 0.4f);
      float confidence = readFloat(fv["confidence"], 0.6f);
      bin.level = max(0.2f, min(1.0f, persistence + confidence * 0.3f));
      bin.glow = readFloat(fv["glow"], confidence);
      state.bins.push_back(bin);
      if (state.bins.size() >= 16) break;
    }
    return;
  }
  JsonArray bins = root["visualizer"]["bins"].as<JsonArray>();
  for (JsonVariant bv : bins) {
    VizBin bin;
    bin.id = String((const char*)(bv["id"] | ""));
    bin.x = readFloat(bv["x"], random(10, 90) / 100.0f);
    bin.y = readFloat(bv["y"], random(10, 90) / 100.0f);
    bin.level = readFloat(bv["level"], 0.2f);
    bin.hue = readFloat(bv["h"], readFloat(bv["hue"], 0.0f));
    bin.sat = readFloat(bv["s"], readFloat(bv["sat"], 0.7f));
    bin.light = readFloat(bv["l"], readFloat(bv["light"], bin.level > 0 ? (0.2f + bin.level * 0.7f) : 0.45f));
    bin.glow = readFloat(bv["glow"], readFloat(bv["glow_level"], bin.level));
    state.bins.push_back(bin);
    if (state.bins.size() >= 16) break;
  }
}

static void pollState() {
  if (sodsBaseUrl.length() == 0) {
    parseState(String(mockStateJson));
    core.state().connOk = false;
    return;
  }
  HTTPClient http;
  String url = sodsBaseUrl + "/opsportal/state";
  http.begin(url);
  int code = http.GET();
  if (code >= 200 && code < 300) {
    String body = http.getString();
    parseState(body);
    core.state().connOk = true;
  } else {
    core.state().connOk = false;
  }
  http.end();
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
}

void PortalDeviceCYD::loop() {
  unsigned long now = millis();
  if (now - lastPollMs > pollIntervalMs) {
    lastPollMs = now;
    ensureWiFi();
    if (WiFi.isConnected()) {
      pollState();
    }
    core.updateTrails();
  }
  if (now - lastRenderMs > 120) {
    lastRenderMs = now;
    updateOrientation();
    core.render(now);
  }
  handleTouch();
  delay(5);
}
