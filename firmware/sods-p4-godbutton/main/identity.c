#include "identity.h"
#include "esp_mac.h"
#include "esp_system.h"
#include <stdio.h>
#include <string.h>

#define FW_VERSION "0.1.0"

static identity_t g_identity;

void identity_build_node_id(char *dest, size_t len) {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  snprintf(dest, len, "p4-%02x%02x%02x", mac[3], mac[4], mac[5]);
}

void identity_init(identity_t *id) {
  if (!id) return;
  memset(id, 0, sizeof(*id));
  identity_build_node_id(id->node_id, sizeof(id->node_id));
  snprintf(id->role, sizeof(id->role), "%s", CONFIG_SODS_ROLE);
  snprintf(id->version, sizeof(id->version), "%s", FW_VERSION);
  snprintf(id->type, sizeof(id->type), "esp32-p4");
  g_identity = *id;
}

const identity_t *identity_get(void) {
  return &g_identity;
}
