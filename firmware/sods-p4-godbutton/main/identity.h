#pragma once

#include <stdbool.h>

typedef struct {
  char node_id[48];
  char role[32];
  char version[16];
  char type[32];
} identity_t;

void identity_init(identity_t *id);
const identity_t *identity_get(void);
void identity_build_node_id(char *dest, size_t len);
