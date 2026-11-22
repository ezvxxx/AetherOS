#ifndef AETHER_H264_STDLIB_H
#define AETHER_H264_STDLIB_H
#include <stddef.h>
void *aether_h264_malloc(size_t size);
void aether_h264_free(void *ptr);
#define malloc aether_h264_malloc
#define free aether_h264_free
#endif
