#pragma once

#include <stdint.h>

void time_sync_init(void);
uint64_t time_sync_unix_ms(void);
const char *time_sync_source(void);
