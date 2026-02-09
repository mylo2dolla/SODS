#include "scan_ble.h"
#include "event_emit.h"
#include "time_sync.h"

static ble_scan_state_t *g_state = NULL;

void scan_ble_init(ble_scan_state_t *state) {
  if (!state) return;
  g_state = state;
  state->last_scan_ms = 0;
  state->last_count = 0;
  state->supported = false;
}

bool scan_ble_run(ble_scan_state_t *state) {
  if (!state) return false;
  if (!g_state) g_state = state;
  if (!state->supported) {
    event_emit_line("ble", "scan.unsupported", "{\"error\":\"ble_not_available\"}");
    return false;
  }
  state->last_scan_ms = (uint32_t)time_sync_unix_ms();
  state->last_count = 0;
  event_emit_line("ble", "scan.summary", "{\"ok\":true,\"count\":0}");
  return true;
}

const ble_scan_state_t *scan_ble_state(void) {
  return g_state;
}
