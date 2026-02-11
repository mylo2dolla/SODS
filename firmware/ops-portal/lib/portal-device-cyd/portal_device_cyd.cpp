#include "portal_device_cyd.h"

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <WebSocketsClient.h>
#include <WebServer.h>
#include <Preferences.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>
#include <utility>

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

#ifndef SODS_LOGGER_URL
#define SODS_LOGGER_URL ""
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
static String sodsLoggerUrl;
static String wifiSsid;
static String wifiPass;

static unsigned long lastPollMs = 0;
static unsigned long pollIntervalMs = 1200;
static unsigned long lastPresetPollMs = 0;
static unsigned long presetPollIntervalMs = 5000;
static unsigned long lastRenderMs = 0;
static bool wifiOk = false;
static unsigned long lastWifiOkMs = 0;
static String lastWifiErr = "";
static bool stationOk = false;
static unsigned long lastStationOkMs = 0;
static bool stationReachable = false;
static bool focusMode = false;
static String focusId = "";
static unsigned long lastReplayStepMs = 0;
static unsigned long replayStartMs = 0;
static std::vector<std::pair<String, String>> aliasMap;

static String lookupAlias(const String &id) {
  for (const auto &pair : aliasMap) {
    if (pair.first == id) return pair.second;
    if ("node:" + pair.first == id) return pair.second;
  }
  return "";
}

static WebSocketsClient wsClient;
static bool wsConnected = false;
static unsigned long lastWsAttemptMs = 0;
static unsigned long wsBackoffMs = 2000;
static String wsHost = "";
static int wsPort = 80;
static String wsPath = "/ws/frames";
static unsigned long lastFrameMs = 0;

static Preferences prefs;
static WebServer configServer(80);
static bool configMode = false;
static bool apiRoutesReady = false;
static bool setupRoutesReady = false;
static bool configServerStarted = false;
static unsigned long lastConfigDrawMs = 0;
static unsigned long bootMs = 0;

static void factoryResetNetworking() {
  prefs.begin("sods", false);
  prefs.clear();
  prefs.end();
  WiFi.disconnect(true, true);
  delay(100);
  ESP.restart();
}

static void ensureConfigServer() {
  if (!apiRoutesReady) {
    configServer.on("/api/factory-reset", HTTP_POST, []() {
      configServer.send(200, "application/json", "{\"ok\":true}");
      delay(150);
      factoryResetNetworking();
    });
    configServer.on("/api/health", HTTP_GET, []() {
      configServer.send(200, "application/json", "{\"ok\":true}");
    });
    apiRoutesReady = true;
  }
  if (!configServerStarted) {
    configServer.begin();
    configServerStarted = true;
  }
}

static String setupSsid() {
  uint64_t mac = ESP.getEfuseMac();
  uint32_t tail = (uint32_t)(mac & 0xFFFFFFu);
  char buf[48];
  snprintf(buf, sizeof(buf), "SODS-Portal-Setup-%06X", tail);
  return String(buf);
}

static void loadConfig() {
  prefs.begin("sods", true);
  wifiSsid = prefs.getString("ssid", WIFI_SSID);
  wifiPass = prefs.getString("pass", WIFI_PASS);
  sodsBaseUrl = prefs.getString("station", SODS_BASE_URL);
  sodsLoggerUrl = prefs.getString("logger", SODS_LOGGER_URL);
  prefs.end();
}

static void saveConfig(const String &ssid, const String &pass, const String &station, const String &logger) {
  prefs.begin("sods", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.putString("station", station);
  prefs.putString("logger", logger);
  prefs.end();
}

static void drawConfigScreen() {
  if (millis() - lastConfigDrawMs < 1000) return;
  lastConfigDrawMs = millis();
  tft.fillScreen(TFT_BLACK);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.setTextSize(1);
  tft.setCursor(10, 10);
  tft.print("SODS Ops Portal Setup");
  tft.setCursor(10, 28);
  tft.print("Station: ");
  tft.print(sodsBaseUrl.length() ? sodsBaseUrl : "not set");
  tft.setCursor(10, 44);
  tft.print("Wi-Fi: ");
  tft.print(wifiSsid.length() ? wifiSsid : "not set");
  tft.setCursor(10, 60);
  if (configMode) {
    tft.print("AP: SODS-Portal-Setup");
    tft.setCursor(10, 76);
    tft.print("Open: http://192.168.4.1");
  } else {
    tft.print("Waiting for Station...");
  }
}

static void startConfigPortal() {
  if (configMode) return;
  configMode = true;
  WiFi.mode(WIFI_AP);
  WiFi.softAP(setupSsid().c_str());
  if (!setupRoutesReady) {
    configServer.on("/", HTTP_GET, []() {
      String stationValue = sodsBaseUrl.length() ? sodsBaseUrl : String(SODS_BASE_URL);
      String loggerValue = sodsLoggerUrl.length() ? sodsLoggerUrl : String(SODS_LOGGER_URL);
      String page =
        "<!doctype html><html><head><meta charset='utf-8'/>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'/>"
        "<title>SODS Portal Setup</title></head><body>"
        "<h2>SODS Ops Portal Setup</h2>"
        "<form method='POST' action='/save'>"
        "Wi-Fi SSID<br/><input name='ssid' /><br/>"
        "Wi-Fi Password<br/><input name='pass' type='password' /><br/>"
        "Station URL<br/><input name='station' value='" + stationValue + "' /><br/>"
        "Logger URL<br/><input name='logger' value='" + loggerValue + "' /><br/>"
        "<button type='submit'>Save</button>"
        "</form></body></html>";
      configServer.send(200, "text/html", page);
    });
    configServer.on("/save", HTTP_POST, []() {
      String ssid = configServer.arg("ssid");
      String pass = configServer.arg("pass");
      String station = configServer.arg("station");
      String logger = configServer.arg("logger");
      if (ssid.length() == 0 || station.length() == 0) {
        configServer.send(400, "text/plain", "SSID and Station URL required.");
        return;
      }
      saveConfig(ssid, pass, station, logger);
      configServer.send(200, "text/plain", "Saved. Rebooting.");
      delay(300);
      ESP.restart();
    });
    setupRoutesReady = true;
  }
  ensureConfigServer();
  drawConfigScreen();
}

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
  bool isPreset = action.cmd.startsWith("preset:");
  bool isRunbook = action.cmd.startsWith("runbook:");
  String url = sodsBaseUrl + (isPreset ? "/api/preset/run" : (isRunbook ? "/api/runbook/run" : "/api/tool/run"));
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  String payload = "{";
  if (isPreset) {
    String id = action.cmd.substring(7);
    payload += "\"id\":\"" + id + "\"";
  } else if (isRunbook) {
    String id = action.cmd.substring(8);
    payload += "\"name\":\"" + id + "\"";
  } else {
    payload += "\"name\":\"" + action.cmd + "\"";
    if (action.argsJson.length() > 0) {
      payload += ",\"input\":" + action.argsJson;
    } else {
      payload += ",\"input\":{}";
    }
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

  if (x < tft.width() / 3 && y < 40) {
    focusMode = !focusMode;
    focusId = "";
    return;
  }

  if (x < tft.width() / 3 && y > 40 && y < 80) {
    core.toggleReplay(millis());
    replayStartMs = millis();
    return;
  }

  if (core.replayEnabled()) {
    int barY = tft.height() - 24;
    if (y >= barY) {
      float progress = (float)x / (float)tft.width();
      core.setReplayProgress(progress);
      return;
    }
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
  String firstId = "";
  for (JsonVariant fv : frames) {
    VizBin bin;
    String id = String((const char*)(fv["device_id"] | fv["node_id"] | fv["id"] | "frame"));
    if (focusMode && focusId.length() && id != focusId) {
      continue;
    }
    if (firstId.length() == 0) firstId = id;
    bin.id = id;
    bin.x = readFloat(fv["x"], 0.1f + hash01(id, 0.2f) * 0.8f);
    bin.y = readFloat(fv["y"], 0.1f + hash01(id, 0.6f) * 0.8f);
    JsonObject color = fv["color"];
    bin.hue = readFloat(color["h"], readFloat(fv["h"], hash01(id, 0.9f) * 360.0f));
    bin.sat = readFloat(color["s"], readFloat(fv["s"], 0.7f));
    bin.light = readFloat(color["l"], readFloat(fv["l"], 0.5f));
    float persistence = readFloat(fv["persistence"], 0.4f);
    float confidence = readFloat(fv["confidence"], 0.6f);
    float depth = readFloat(fv["z"], 0.6f);
    float rssi = readFloat(fv["rssi"], -70.0f);
    float rssiNorm = (rssi + 100.0f) / 70.0f;
    rssiNorm = max(0.0f, min(1.0f, rssiNorm));
    bin.level = max(0.2f, min(1.0f, persistence + confidence * 0.3f + rssiNorm * 0.2f + depth * 0.2f));
    bin.glow = readFloat(fv["glow"], confidence);
    bin.glow = max(bin.glow, depth * 0.4f);
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
  if (focusMode) {
    if (focusId.length()) {
      String alias = lookupAlias(focusId);
      String label = alias.length() ? alias : focusId;
      int lastColon = label.lastIndexOf(':');
      if (lastColon >= 0 && lastColon + 1 < label.length()) {
        label = label.substring(lastColon + 1);
      }
      if (label.length() > 12) label = label.substring(label.length() - 12);
      core.setFocusLabel("focus:" + label);
    } else {
      core.setFocusLabel("focus");
    }
  } else {
    core.setFocusLabel(core.replayEnabled() ? "replay" : "utility");
  }
}

static void parsePortalState(const String &json) {
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
  JsonObject logger = root["logger"];
  if (!logger.isNull()) {
    state.loggerOk = logger["ok"] | false;
    state.loggerStatus = String((const char*)(logger["status"] | ""));
    state.loggerLastEventMs = logger["last_event_ms"] | 0;
  }

  PortalState &s = core.state();
  s.buttons.clear();
  auto pushButton = [&](const String &id, const String &label, const String &kind, const String &cmd, float glow) {
    ButtonState b;
    b.id = id;
    b.label = label;
    b.kind = kind;
    b.enabled = true;
    b.glow = glow;
    ButtonAction a;
    a.id = id;
    a.label = label;
    a.cmd = cmd;
    b.actions.push_back(a);
    s.buttons.push_back(b);
  };

  JsonObject runbooks = root["runbooks"];
  JsonArray runbookItems = runbooks["items"].as<JsonArray>();
  if (!runbookItems.isNull() && runbookItems.size() > 0) {
    for (JsonVariant v : runbookItems) {
      String id = String((const char*)(v["id"] | ""));
      String title = String((const char*)(v["title"] | id.c_str()));
      JsonObject ui = v["ui"];
      bool capsule = ui["capsule"] | true;
      if (!capsule) continue;
      pushButton(id, title, "runbook", "runbook:" + id, 0.5f);
      if (s.buttons.size() >= 6) break;
    }
  }

  if (s.buttons.empty()) {
    JsonArray presets = root["presets"]["items"].as<JsonArray>();
    if (!presets.isNull()) {
      for (JsonVariant v : presets) {
        JsonObject ui = v["ui"];
        bool capsule = ui["capsule"] | false;
        if (!capsule) continue;
        String id = String((const char*)(v["id"] | ""));
        String title = String((const char*)(v["title"] | id.c_str()));
        pushButton(id, title, "preset", "preset:" + id, 0.4f);
        if (s.buttons.size() >= 6) break;
      }
    }
  }

  if (s.buttons.empty()) {
    JsonArray toolItems = root["tools"]["items"].as<JsonArray>();
    if (!toolItems.isNull()) {
      for (JsonVariant v : toolItems) {
        String id = String((const char*)(v["name"] | ""));
        String label = id;
        int dot = label.lastIndexOf('.');
        if (dot >= 0 && dot + 1 < label.length()) label = label.substring(dot + 1);
        String kind = String((const char*)(v["kind"] | ""));
        pushButton(id, label, kind, id, 0.2f);
        if (s.buttons.size() >= 6) break;
      }
    }
  }

  JsonArray frames = root["frames"].as<JsonArray>();
  if (!frames.isNull() && frames.size() > 0) {
    applyFrames(frames);
    if (focusMode && focusId.length() == 0 && core.state().bins.size() > 0) {
      focusId = core.state().bins[0].id;
    }
  }

  JsonObject aliasObj = root["aliases"].as<JsonObject>();
  if (!aliasObj.isNull()) {
    aliasMap.clear();
    for (JsonPair kv : aliasObj) {
      String id = String(kv.key().c_str());
      String alias = String((const char*)kv.value().as<const char*>());
      if (id.length() && alias.length()) {
        aliasMap.push_back({id, alias});
      }
    }
  }

  JsonObject actions = root["actions"];
  if (!actions.isNull()) {
    JsonObject tool = actions["tool"];
    JsonObject runbook = actions["runbook"];
    if (!runbook.isNull() && String((const char*)(runbook["id"] | "")).length()) {
      s.actionLabel = String("runbook ") + String((const char*)(runbook["id"] | ""));
      s.actionState = String((const char*)(runbook["status"] | ""));
    } else if (!tool.isNull() && String((const char*)(tool["name"] | "")).length()) {
      s.actionLabel = String("tool ") + String((const char*)(tool["name"] | ""));
      s.actionState = String((const char*)(tool["status"] | ""));
    } else {
      s.actionLabel = "";
      s.actionState = "";
    }
  } else {
    s.actionLabel = "";
    s.actionState = "";
  }

  JsonArray quickStats = root["quick_stats"].as<JsonArray>();
  if (!quickStats.isNull()) {
    s.quick1 = String((const char*)(quickStats[0] | ""));
    s.quick2 = String((const char*)(quickStats[1] | ""));
    s.quick3 = String((const char*)(quickStats[2] | ""));
  } else {
    s.quick1 = "";
    s.quick2 = "";
    s.quick3 = "";
  }
}

static void parsePresets(const String &json) {
  DynamicJsonDocument doc(8192);
  DeserializationError err = deserializeJson(doc, json);
  if (err) return;
  JsonObject root = doc.as<JsonObject>();
  JsonArray presets = root["presets"].as<JsonArray>();
  if (presets.isNull()) return;
  PortalState &state = core.state();
  state.buttons.clear();
  for (JsonVariant v : presets) {
    JsonObject ui = v["ui"];
    bool capsule = ui["capsule"] | false;
    if (!capsule) continue;
    ButtonState b;
    String id = String((const char*)(v["id"] | ""));
    String title = String((const char*)(v["title"] | id.c_str()));
    b.id = id;
    b.label = title;
    b.kind = "preset";
    b.enabled = true;
    b.glow = 0.4f;
    ButtonAction a;
    a.id = id;
    a.label = title;
    a.cmd = "preset:" + id;
    b.actions.push_back(a);
    state.buttons.push_back(b);
    if (state.buttons.size() >= 6) break;
  }
}

static void pollPortalState() {
  PortalState &state = core.state();
  if (sodsBaseUrl.length() == 0) {
    state.connOk = false;
    state.connErr = "station_url_missing";
    state.loggerOk = false;
    state.loggerStatus = "unconfigured";
    state.nodesOnline = 0;
    state.nodesTotal = 0;
    return;
  }
  HTTPClient http;
  String url = sodsBaseUrl + "/api/portal/state";
  http.begin(url);
  int code = http.GET();
  if (code >= 200 && code < 300) {
    String body = http.getString();
    parsePortalState(body);
    stationOk = true;
    lastStationOkMs = millis();
  } else {
    stationOk = false;
    state.connOk = false;
    state.connErr = String("station_http_") + String(code);
    state.loggerOk = false;
    state.loggerStatus = "error";
  }
  http.end();
}

static void pollPresets() {
  if (sodsBaseUrl.length() == 0) return;
  HTTPClient http;
  String url = sodsBaseUrl + "/api/presets";
  http.begin(url);
  int code = http.GET();
  if (code >= 200 && code < 300) {
    String body = http.getString();
    parsePresets(body);
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
  if (configMode) {
    configServer.handleClient();
    return;
  }
  if (WiFi.isConnected()) {
    wifiOk = true;
    lastWifiOkMs = millis();
    return;
  }
  if (wifiSsid.length() == 0) {
    wifiOk = false;
    lastWifiErr = "wifi ssid missing";
    startConfigPortal();
    return;
  }
  if (millis() - lastWifiOkMs > 20000 && !WiFi.isConnected()) {
    lastWifiErr = "wifi timeout";
    startConfigPortal();
    return;
  }
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(wifiSsid.c_str(), wifiPass.c_str());
}

void PortalDeviceCYD::setup() {
  Serial.begin(115200);
  delay(200);
  bootMs = millis();

  loadConfig();
  ensureConfigServer();

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

  if (sodsBaseUrl.length() == 0) {
    startConfigPortal();
  }
  ensureWiFi();
  if (parseBaseUrl(sodsBaseUrl, wsHost, wsPort)) {
    wsClient.onEvent(handleWsEvent);
  }
}

void PortalDeviceCYD::loop() {
  unsigned long now = millis();
  configServer.handleClient();
  if (configMode) {
    drawConfigScreen();
    delay(20);
    return;
  }
  if (now - lastPollMs > pollIntervalMs) {
    lastPollMs = now;
    ensureWiFi();
    if (WiFi.isConnected()) {
      pollPortalState();
    } else {
      core.state().connErr = lastWifiErr;
    }
    core.updateTrails();
  }
  if (now - lastPresetPollMs > presetPollIntervalMs) {
    lastPresetPollMs = now;
  }
  stationReachable = stationOk;
  if (!stationReachable) {
    // If we can't reach station after a reasonable boot window, open the setup AP.
    // This keeps the device claimable even if the display is misconfigured or station URL is wrong.
    if (now - bootMs > 15000 && !configMode) {
      startConfigPortal();
    }
    drawConfigScreen();
    delay(20);
    return;
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
