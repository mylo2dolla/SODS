#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
  MODE_IDLE = 0,
  MODE_FIELD = 1,
  MODE_RELAY = 2
} god_mode_t;

typedef struct {
  god_mode_t mode;
  bool wifi_connected;
  bool devstation_reachable;
  bool logger_reachable;
  uint32_t last_scan_ms;
  uint32_t buffer_count;
  bool buffer_pressure;
} god_context_t;

void god_button_init(void);
void god_button_update_context(const god_context_t *ctx);
bool god_button_run_all(void);
const god_context_t *god_button_context(void);
