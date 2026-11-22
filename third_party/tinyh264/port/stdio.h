#ifndef AETHER_H264_STDIO_H
#define AETHER_H264_STDIO_H
typedef struct { int unused; } FILE;
extern FILE *stderr;
extern FILE *stdout;
int fprintf(FILE *stream, const char *format, ...);
int printf(const char *format, ...);
#endif
