#ifndef STL_H
#define STL_H

#include <stdbool.h>
#include <stddef.h>

// Queue node
typedef struct queue_node_s {
  void* data;
  struct queue_node_s* next;
} queue_node_t;

// FIFO queue
typedef struct {
  queue_node_t* head;  // queue head (dequeue end)
  queue_node_t* tail;  // queue tail (enqueue end)
  size_t size;         // queue size
} queue_t;

queue_t* queue_init(void);
void queue_destroy(queue_t* queue);

int queue_enqueue(queue_t* queue, void* data);
void* queue_dequeue(queue_t* queue);

void* queue_peek(queue_t* queue);
bool queue_is_empty(queue_t* queue);
size_t queue_size(queue_t* queue);

#endif  // STL_H