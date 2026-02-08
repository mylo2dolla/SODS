#pragma once

#include "ring_buffer.h"
#include <stdbool.h>

void event_emit_init(ring_buffer_t *rb);
bool event_emit_line(const char *domain, const char *type, const char *data_json);
const ring_buffer_t *event_emit_buffer(void);
