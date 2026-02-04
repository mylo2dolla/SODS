#include <Arduino.h>
#include "portal_device_cyd.h"

static PortalDeviceCYD device;

void setup() {
  device.setup();
}

void loop() {
  device.loop();
}
