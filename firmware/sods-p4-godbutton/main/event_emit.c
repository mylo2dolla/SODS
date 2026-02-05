#include "event_emit.h"
#include "identity.h"
#include "time_sync.h"
#include <stdio.h>
#include <string.h>

static ring_buffer_t *g_buffer = NULL;

void event_emit_init(ring_buffer_t *rb) {
  g_buffer = rb;
}

const ring_buffer_t *event_emit_buffer(void) {
  return g_buffer;
}

bool event_emit_line(const char *domain, const char *type, const char *data_json) {
  if (!g_buffer || !domain || !type) return false;
  const identity_t *id = identity_get();
  uint64_t ts = time_sync_unix_ms();
  char line[512];
  if (!data_json) data_json = "{}";
  snprintf(line, sizeof(line),
           "{\"node_id\":\"%s\",\"ts\":%llu,\"domain\":\"%s\",\"type\":\"%s\",\"data\":%s}",
           id->node_id,
           (unsigned long long)ts,
           domain,
           type,
           data_json);
  return ring_buffer_push(g_buffer, line);
}
