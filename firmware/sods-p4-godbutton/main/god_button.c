#include "god_button.h"
#include "event_emit.h"
#include "scan_wifi.h"
#include "scan_ble.h"

typedef struct {
  const char *name;
  bool (*can_run)(const god_context_t *ctx);
  bool (*run)(void);
} action_t;

static god_context_t g_ctx;
static wifi_scan_state_t g_wifi_state;
static ble_scan_state_t g_ble_state;

static bool can_run_any(const god_context_t *ctx) {
  return ctx && ctx->mode != MODE_IDLE;
}

static bool can_run_wifi(const god_context_t *ctx) {
  return can_run_any(ctx) && ctx->wifi_connected;
}

static bool action_heartbeat(void) {
  return event_emit_line("sys", "heartbeat", "{}");
}

static bool action_identity(void) {
  return event_emit_line("sys", "identity.emit", "{}");
}

static bool action_wifi_scan(void) {
  return scan_wifi_run(&g_wifi_state);
}

static bool action_ble_scan(void) {
  return scan_ble_run(&g_ble_state);
}

static action_t g_actions[] = {
  { "sys.heartbeat", can_run_any, action_heartbeat },
  { "sys.identity", can_run_any, action_identity },
  { "wifi.scan.passive", can_run_wifi, action_wifi_scan },
  { "ble.scan.passive", can_run_any, action_ble_scan },
};

void god_button_init(void) {
  g_ctx.mode = MODE_IDLE;
  g_ctx.wifi_connected = false;
  g_ctx.devstation_reachable = false;
  g_ctx.logger_reachable = false;
  g_ctx.last_scan_ms = 0;
  g_ctx.buffer_count = 0;
  g_ctx.buffer_pressure = false;
  scan_wifi_init(&g_wifi_state);
  scan_ble_init(&g_ble_state);
}

void god_button_update_context(const god_context_t *ctx) {
  if (!ctx) return;
  g_ctx = *ctx;
}

const god_context_t *god_button_context(void) {
  return &g_ctx;
}

bool god_button_run_all(void) {
  bool ok = true;
  for (size_t i = 0; i < sizeof(g_actions) / sizeof(g_actions[0]); ++i) {
    if (g_actions[i].can_run && !g_actions[i].can_run(&g_ctx)) {
      continue;
    }
    if (g_actions[i].run && !g_actions[i].run()) {
      ok = false;
    }
  }
  return ok;
}
