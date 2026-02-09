#pragma once

#include <stdint.h>
#include <stdbool.h>

typedef struct {
  uint32_t last_scan_ms;
  uint16_t last_count;
} wifi_scan_state_t;

void scan_wifi_init(wifi_scan_state_t *state);
bool scan_wifi_run(wifi_scan_state_t *state);
const wifi_scan_state_t *scan_wifi_state(void);
