#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"

/* Freestanding libc primitives used by minimp3. */
void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; ++i) d[i] = s[i];
    return dst;
}
void *memmove(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    if (d < s) for (size_t i = 0; i < n; ++i) d[i] = s[i];
    else if (d > s) for (size_t i = n; i != 0; --i) d[i - 1] = s[i - 1];
    return dst;
}
void *memset(void *dst, int value, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    for (size_t i = 0; i < n; ++i) d[i] = (uint8_t)value;
    return dst;
}

static mp3dec_t decoder;
static const uint8_t *input_data;
static size_t input_length;
static size_t input_offset;
static mp3d_sample_t frame_samples[MINIMP3_MAX_SAMPLES_PER_FRAME];

void aether_mp3_init(const uint8_t *data, size_t length) {
    mp3dec_init(&decoder);
    input_data = data;
    input_length = length;
    input_offset = 0;
}

int aether_mp3_next(int *sample_rate, int *channels) {
    while (input_offset + 4 <= input_length) {
        mp3dec_frame_info_t info;
        int samples = mp3dec_decode_frame(&decoder, input_data + input_offset,
            (int)(input_length - input_offset), frame_samples, &info);
        if (info.frame_bytes <= 0) {
            input_offset++;
            continue;
        }
        input_offset += (size_t)info.frame_bytes;
        if (samples <= 0 || info.channels <= 0 || info.hz <= 0) continue;
        *sample_rate = info.hz;
        *channels = info.channels;
        return samples;
    }
    return 0;
}

const mp3d_sample_t *aether_mp3_samples(void) { return frame_samples; }
