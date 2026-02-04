#include "portal_core.h"

PortalCore::PortalCore() = default;

void PortalCore::begin(TFT_eSPI *tftRef) {
  tft = tftRef;
}

void PortalCore::setMode(PortalMode mode) {
  currentMode = mode;
}

PortalMode PortalCore::mode() const {
  return currentMode;
}

void PortalCore::setScreen(int w, int h) {
  screenW = w;
  screenH = h;
}

PortalState &PortalCore::state() {
  return stateValue;
}

bool PortalCore::hitButton(int x, int y, int &idx) const {
  if (currentMode != PortalMode::Utility) return false;
  int rightW = screenW / 3;
  int startX = screenW - rightW + 8;
  int btnY = 12;
  int w = rightW - 16;
  int h = 30;
  int spacing = 10;
  for (size_t i = 0; i < stateValue.buttons.size(); i++) {
    if (x >= startX && x <= startX + w && y >= btnY && y <= btnY + h) {
      idx = (int)i;
      return true;
    }
    btnY += h + spacing;
  }
  return false;
}

void PortalCore::toggleOverlay(unsigned long nowMs) {
  overlayOn = !overlayOn;
  overlayHideAtMs = overlayOn ? nowMs + 2500 : 0;
}

bool PortalCore::overlayVisible() const {
  return overlayOn;
}

void PortalCore::showPopup(int buttonIdx, unsigned long nowMs) {
  popup.active = true;
  popup.buttonIdx = buttonIdx;
  popup.hideAtMs = nowMs + 3000;
  popup.itemRects.clear();
}

int PortalCore::popupHit(int x, int y) const {
  if (!popup.active || popup.buttonIdx < 0) return -1;
  for (size_t i = 0; i < popup.itemRects.size(); i++) {
    const auto &r = popup.itemRects[i];
    if (x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h) return (int)i;
  }
  return -1;
}

bool PortalCore::popupActive() const {
  return popup.active;
}

int PortalCore::popupButtonIdx() const {
  return popup.buttonIdx;
}

void PortalCore::dismissPopup() {
  popup.active = false;
  popup.buttonIdx = -1;
  popup.itemRects.clear();
}

void PortalCore::updateTrails() {
  for (int i = 0; i < 16; i++) {
    for (auto &p : trails[i]) {
      if (p.age < 255) p.age++;
    }
    while (!trails[i].empty() && trails[i].front().age > 12) {
      trails[i].erase(trails[i].begin());
    }
  }
}

void PortalCore::render(unsigned long nowMs) {
  if (!tft) return;

  if (overlayOn && overlayHideAtMs > 0 && nowMs > overlayHideAtMs) {
    overlayOn = false;
  }

  if (popup.active && popup.hideAtMs > 0 && nowMs > popup.hideAtMs) {
    dismissPopup();
  }

  drawBackground();

  if (currentMode == PortalMode::Utility) {
    drawStatusLeft();
    int leftW = screenW - (screenW / 3);
    int vizX = 10;
    int vizY = 90;
    int vizW = leftW - 20;
    int vizH = screenH - vizY - 14;
    drawVisualizer(vizX, vizY, vizW, vizH);
    drawButtonsRight();
  } else {
    drawVisualizer(8, 8, screenW - 16, screenH - 16);
    if (overlayOn) drawWatchOverlay();
  }

  if (popup.active) drawPopup();
}

void PortalCore::drawBackground() {
  if (!tft) return;
  tft->fillScreen(TFT_BLACK);
  uint16_t border = tft->color565(90, 20, 20);
  tft->drawRect(0, 0, screenW, screenH, border);
  if (currentMode == PortalMode::Utility) {
    int leftW = screenW - (screenW / 3);
    tft->drawRect(0, 0, leftW, screenH, tft->color565(50, 20, 20));
    tft->drawFastVLine(leftW, 0, screenH, tft->color565(120, 40, 40));
  }
}

void PortalCore::drawStatusLeft() {
  if (!tft) return;
  tft->setTextColor(TFT_WHITE, TFT_BLACK);
  tft->setTextSize(1);
  tft->setCursor(10, 10);
  tft->print("SODS Ops Portal");
  tft->setCursor(10, 24);
  tft->print("conn: ");
  tft->print(stateValue.connOk ? "ok" : "err");
  tft->setCursor(10, 38);
  tft->print("mode: ");
  tft->print(stateValue.modeName);
  tft->setCursor(10, 52);
  tft->print("nodes: ");
  tft->print(stateValue.nodesOnline);
  tft->print("/");
  tft->print(stateValue.nodesTotal);
  tft->setCursor(10, 66);
  tft->print("logger: ");
  tft->print(stateValue.loggerOk ? "ok" : "err");
  tft->setCursor(10, 80);
  tft->print("ingest ok:");
  tft->print(stateValue.ingestOkRate, 1);
  tft->setCursor(10, 94);
  tft->print("ingest err:");
  tft->print(stateValue.ingestErrRate, 1);
}

void PortalCore::drawButtonsRight() {
  if (!tft) return;
  int rightW = screenW / 3;
  int startX = screenW - rightW + 8;
  int y = 12;
  int w = rightW - 16;
  int h = 30;
  int spacing = 10;
  for (size_t i = 0; i < stateValue.buttons.size(); i++) {
    ButtonState &b = stateValue.buttons[i];
    uint16_t base = b.enabled ? tft->color565(30, 30, 35) : tft->color565(15, 15, 18);
    uint16_t border = tft->color565(150, 40, 40);
    uint16_t glow = tft->color565(255, 60, 60);
    tft->fillRoundRect(startX, y, w, h, 14, base);
    tft->drawRoundRect(startX, y, w, h, 14, border);
    if (b.glow > 0.1f) {
      uint16_t gcol = dimColor(glow, b.glow);
      tft->drawRoundRect(startX - 1, y - 1, w + 2, h + 2, 16, gcol);
    }
    tft->setTextColor(TFT_WHITE, base);
    tft->setTextSize(1);
    tft->setCursor(startX + 8, y + 10);
    tft->print(b.label);
    y += h + spacing;
    if (y + h > screenH - 10) break;
  }
}

void PortalCore::drawVisualizer(int x, int y, int w, int h) {
  if (!tft) return;
  tft->drawRect(x - 2, y - 2, w + 4, h + 4, tft->color565(120, 40, 40));
  if (stateValue.bins.empty()) {
    tft->setTextColor(TFT_WHITE, TFT_BLACK);
    tft->setTextSize(1);
    tft->setCursor(x + 10, y + 10);
    tft->print("Waiting for frames...");
    return;
  }
  for (size_t i = 0; i < stateValue.bins.size() && i < 16; i++) {
    VizBin &bin = stateValue.bins[i];
    int px = x + (int)(bin.x * (w - 6)) + 3;
    int py = y + (int)(bin.y * (h - 6)) + 3;
    uint16_t color = hslTo565(bin.hue, bin.sat, bin.light);
    float glowStrength = bin.glow;
    trails[i].push_back({px, py, 0});
    if (trails[i].size() > 12) trails[i].erase(trails[i].begin());
    if (glowStrength > 0.05f) {
      uint16_t gcol = dimColor(color, 0.2f + glowStrength * 0.8f);
      int gr = (int)(6 + glowStrength * 10);
      tft->fillCircle(px, py, gr, gcol);
    }
    for (size_t t = 0; t < trails[i].size(); t++) {
      float fade = 1.0f - (float)t / trails[i].size();
      uint16_t c = dimColor(color, 0.2f + fade * 0.8f);
      tft->fillCircle(trails[i][t].x, trails[i][t].y, (int)(2 + bin.level * 4 * fade), c);
    }
  }
}

void PortalCore::drawWatchOverlay() {
  if (!tft) return;
  int w = screenW - 40;
  int h = 70;
  int x = 20;
  int y = 20;
  uint16_t base = tft->color565(20, 20, 24);
  uint16_t border = tft->color565(180, 50, 50);
  tft->fillRoundRect(x, y, w, h, 10, base);
  tft->drawRoundRect(x, y, w, h, 10, border);
  tft->setTextColor(TFT_WHITE, base);
  tft->setTextSize(1);
  tft->setCursor(x + 10, y + 12);
  tft->print(stateValue.connOk ? "conn: ok" : "conn: err");
  tft->setCursor(x + 10, y + 28);
  tft->print("nodes: ");
  tft->print(stateValue.nodesOnline);
  tft->print("/");
  tft->print(stateValue.nodesTotal);
  tft->setCursor(x + 10, y + 44);
  tft->print("logger: ");
  tft->print(stateValue.loggerOk ? "ok" : "err");
}

void PortalCore::drawPopup() {
  if (!tft || popup.buttonIdx < 0 || popup.buttonIdx >= (int)stateValue.buttons.size()) return;
  const auto &button = stateValue.buttons[popup.buttonIdx];
  if (button.actions.empty()) return;

  int rightW = screenW / 3;
  int x = screenW - rightW + 4;
  int y = screenH - (int)button.actions.size() * 26 - 12;
  int w = rightW - 8;
  int h = (int)button.actions.size() * 26 + 8;
  uint16_t base = tft->color565(18, 18, 22);
  uint16_t border = tft->color565(200, 50, 50);
  tft->fillRoundRect(x, y, w, h, 10, base);
  tft->drawRoundRect(x, y, w, h, 10, border);

  popup.itemRects.clear();
  int itemY = y + 6;
  for (size_t i = 0; i < button.actions.size(); i++) {
    const auto &action = button.actions[i];
    tft->setTextColor(TFT_WHITE, base);
    tft->setTextSize(1);
    tft->setCursor(x + 8, itemY + 8);
    tft->print(action.label.length() ? action.label : action.id);
    popup.itemRects.push_back({x + 4, itemY, w - 8, 22});
    itemY += 24;
  }
}

uint16_t PortalCore::hslTo565(float h, float s, float l) const {
  float c = (1.0f - fabs(2.0f * l - 1.0f)) * s;
  float hprime = fmod(h / 60.0f, 6.0f);
  float x = c * (1.0f - fabs(fmod(hprime, 2.0f) - 1.0f));
  float r = 0, g = 0, b = 0;
  if (0 <= hprime && hprime < 1) { r = c; g = x; }
  else if (1 <= hprime && hprime < 2) { r = x; g = c; }
  else if (2 <= hprime && hprime < 3) { g = c; b = x; }
  else if (3 <= hprime && hprime < 4) { g = x; b = c; }
  else if (4 <= hprime && hprime < 5) { r = x; b = c; }
  else if (5 <= hprime && hprime < 6) { r = c; b = x; }
  float m = l - c / 2.0f;
  r += m; g += m; b += m;
  uint8_t R = (uint8_t)(r * 255);
  uint8_t G = (uint8_t)(g * 255);
  uint8_t B = (uint8_t)(b * 255);
  return tft->color565(R, G, B);
}

uint16_t PortalCore::dimColor(uint16_t color, float factor) const {
  uint8_t r = (color >> 11) & 0x1F;
  uint8_t g = (color >> 5) & 0x3F;
  uint8_t b = color & 0x1F;
  r = (uint8_t)(r * factor);
  g = (uint8_t)(g * factor);
  b = (uint8_t)(b * factor);
  return (r << 11) | (g << 5) | b;
}
