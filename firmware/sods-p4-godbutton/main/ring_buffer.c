#include "ring_buffer.h"
#include <stdlib.h>
#include <string.h>

static void free_slot(char **slot) {
  if (slot && *slot) {
    free(*slot);
    *slot = NULL;
  }
}

bool ring_buffer_init(ring_buffer_t *rb, size_t capacity) {
  if (!rb || capacity == 0) return false;
  rb->lines = calloc(capacity, sizeof(char *));
  if (!rb->lines) return false;
  rb->capacity = capacity;
  rb->count = 0;
  rb->head = 0;
  return true;
}

void ring_buffer_free(ring_buffer_t *rb) {
  if (!rb || !rb->lines) return;
  for (size_t i = 0; i < rb->capacity; ++i) {
    free_slot(&rb->lines[i]);
  }
  free(rb->lines);
  rb->lines = NULL;
  rb->capacity = 0;
  rb->count = 0;
  rb->head = 0;
}

void ring_buffer_clear(ring_buffer_t *rb) {
  if (!rb || !rb->lines) return;
  for (size_t i = 0; i < rb->capacity; ++i) {
    free_slot(&rb->lines[i]);
  }
  rb->count = 0;
  rb->head = 0;
}

bool ring_buffer_push(ring_buffer_t *rb, const char *line) {
  if (!rb || !rb->lines || !line) return false;
  size_t slot = (rb->head + rb->count) % rb->capacity;
  if (rb->count == rb->capacity) {
    slot = rb->head;
    free_slot(&rb->lines[slot]);
    rb->head = (rb->head + 1) % rb->capacity;
  } else {
    rb->count++;
  }
  rb->lines[slot] = strdup(line);
  return rb->lines[slot] != NULL;
}

size_t ring_buffer_count(const ring_buffer_t *rb) {
  return rb ? rb->count : 0;
}

const char *ring_buffer_get(const ring_buffer_t *rb, size_t index) {
  if (!rb || !rb->lines || index >= rb->count) return NULL;
  size_t slot = (rb->head + index) % rb->capacity;
  return rb->lines[slot];
}
