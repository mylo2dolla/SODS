#pragma once

#include <stdint.h>
#include <stdbool.h>

typedef struct {
  uint32_t last_scan_ms;
  uint16_t last_count;
  bool supported;
} ble_scan_state_t;

void scan_ble_init(ble_scan_state_t *state);
bool scan_ble_run(ble_scan_state_t *state);
const ble_scan_state_t *scan_ble_state(void);
