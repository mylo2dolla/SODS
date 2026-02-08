#pragma once

#include <stddef.h>
#include <stdbool.h>

typedef struct {
  char **lines;
  size_t capacity;
  size_t count;
  size_t head;
} ring_buffer_t;

bool ring_buffer_init(ring_buffer_t *rb, size_t capacity);
void ring_buffer_free(ring_buffer_t *rb);
void ring_buffer_clear(ring_buffer_t *rb);
bool ring_buffer_push(ring_buffer_t *rb, const char *line);
size_t ring_buffer_count(const ring_buffer_t *rb);
const char *ring_buffer_get(const ring_buffer_t *rb, size_t index);
