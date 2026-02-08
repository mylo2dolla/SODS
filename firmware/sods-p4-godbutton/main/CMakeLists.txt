idf_component_register(
  SRCS
    "app_main.c"
    "http_server.c"
    "god_button.c"
    "scan_wifi.c"
    "scan_ble.c"
    "ring_buffer.c"
    "event_emit.c"
    "time_sync.c"
    "identity.c"
  INCLUDE_DIRS "."
)
