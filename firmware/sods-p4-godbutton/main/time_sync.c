#include "time_sync.h"
#include "esp_timer.h"
#include <time.h>

static const char *g_time_source = "uptime";

void time_sync_init(void) {
  g_time_source = "uptime";
}

uint64_t time_sync_unix_ms(void) {
  time_t now = time(NULL);
  if (now > 1000000000) {
    g_time_source = "rtc";
    return (uint64_t)now * 1000ULL;
  }
  g_time_source = "uptime";
  return (uint64_t)(esp_timer_get_time() / 1000ULL);
}

const char *time_sync_source(void) {
  return g_time_source;
}
