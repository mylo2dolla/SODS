#pragma once

#include <Arduino.h>
#include <TFT_eSPI.h>
#include <vector>

struct ButtonAction {
  String id;
  String label;
  String cmd;
  String argsJson;
};

struct ButtonState {
  String id;
  String label;
  String kind;
  bool enabled = true;
  float glow = 0.0f;
  std::vector<ButtonAction> actions;
};

struct VizBin {
  String id;
  float x = 0.5f;
  float y = 0.5f;
  float level = 0.0f;
  float hue = 0.0f;
  float sat = 0.6f;
  float light = 0.5f;
  float glow = 0.0f;
};

struct PortalState {
  bool connOk = false;
  unsigned long connLastOkMs = 0;
  String connErr;
  bool loggerOk = false;
  String loggerStatus;
  unsigned long loggerLastEventMs = 0;
  String modeName;
  unsigned long modeSinceMs = 0;
  int nodesTotal = 0;
  int nodesOnline = 0;
  unsigned long nodesLastAnnounceMs = 0;
  float ingestOkRate = 0;
  float ingestErrRate = 0;
  unsigned long ingestLastOkMs = 0;
  unsigned long ingestLastErrMs = 0;
  std::vector<ButtonState> buttons;
  std::vector<VizBin> bins;
};

enum class PortalMode {
  Utility,
  Watch,
};

class PortalCore {
public:
  PortalCore();

  void begin(TFT_eSPI *tft);
  void setMode(PortalMode mode);
  PortalMode mode() const;
  void setScreen(int w, int h);

  PortalState &state();

  void render(unsigned long nowMs);
  void updateTrails();

  bool hitButton(int x, int y, int &idx) const;

  void toggleOverlay(unsigned long nowMs);
  bool overlayVisible() const;

  void showPopup(int buttonIdx, unsigned long nowMs);
  int popupHit(int x, int y) const;
  bool popupActive() const;
  int popupButtonIdx() const;
  void dismissPopup();

private:
  struct TrailPoint {
    int x = 0;
    int y = 0;
    uint8_t age = 0;
  };

  struct PopupRect {
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
  };

  struct PopupState {
    bool active = false;
    int buttonIdx = -1;
    unsigned long hideAtMs = 0;
    std::vector<PopupRect> itemRects;
  };

  TFT_eSPI *tft = nullptr;
  PortalState stateValue;
  PortalMode currentMode = PortalMode::Utility;
  int screenW = 240;
  int screenH = 320;

  unsigned long overlayHideAtMs = 0;
  bool overlayOn = false;
  PopupState popup;

  std::vector<TrailPoint> trails[16];

  void drawBackground();
  void drawStatusLeft();
  void drawVisualizer(int x, int y, int w, int h);
  void drawButtonsRight();
  void drawWatchOverlay();
  void drawPopup();

  uint16_t hslTo565(float h, float s, float l) const;
  uint16_t dimColor(uint16_t color, float factor) const;
};
