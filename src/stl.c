#include "stl.h"

#include <stdlib.h>

// Initialize queue
queue_t* queue_init(void) {
  queue_t* queue = malloc(sizeof(queue_t));
  if (!queue) return NULL;
  queue->head = NULL;
  queue->tail = NULL;
  queue->size = 0;
  return queue;
}

// Destroy queue (does not free user data)
void queue_destroy(queue_t* queue) {
  if (!queue) return;

  while (!queue_is_empty(queue)) {
    queue_dequeue(queue);
  }
  free(queue);
}

// Enqueue (add to tail)
int queue_enqueue(queue_t* queue, void* data) {
  if (!queue) return -1;

  queue_node_t* node = malloc(sizeof(queue_node_t));
  if (!node) return -1;  // memory allocation failed

  node->data = data;
  node->next = NULL;

  if (queue->tail) {
    queue->tail->next = node;
  } else {
    // queue is empty, new node is both head and tail
    queue->head = node;
  }

  queue->tail = node;
  queue->size++;
  return 0;
}

// Dequeue (remove from head)
void* queue_dequeue(queue_t* queue) {
  if (!queue || queue_is_empty(queue)) {
    return NULL;
  }

  queue_node_t* node = queue->head;
  void* data = node->data;

  queue->head = node->next;
  if (!queue->head) {
    // queue becomes empty, tail pointer should also be null
    queue->tail = NULL;
  }

  free(node);
  queue->size--;
  return data;
}

// Peek at head element (does not remove)
void* queue_peek(queue_t* queue) {
  if (!queue || queue_is_empty(queue)) {
    return NULL;
  }

  return queue->head->data;
}

// Check if queue is empty
bool queue_is_empty(queue_t* queue) { return !queue || queue->head == NULL; }

// Get queue size
size_t queue_size(queue_t* queue) { return queue ? queue->size : 0; }