/*
 * crescendo_ffmpeg.c - the av_log -> sink trampoline (the shim's only code;
 * the constants are header-only). See crescendo_ffmpeg.h for the design;
 * the short version: the va_list never leaves this file.
 */

#include "crescendo_ffmpeg.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <string.h>

#include "libavutil/log.h"

/* The installed sink. Atomic because the trampoline reads it from arbitrary
 * FFmpeg threads while install may run on another; acquire/release pairs the
 * pointer with whatever state the installer set up before publishing it. */
static _Atomic crescendo_ffmpeg_log_sink g_sink = NULL;

static void crescendo_ffmpeg_log_trampoline(void *avcl, int level, const char *fmt, va_list vl) {
    crescendo_ffmpeg_log_sink sink = atomic_load_explicit(&g_sink, memory_order_acquire);
    if (sink == NULL || fmt == NULL) {
        return;
    }
    /* FFmpeg packs an optional terminal-color tint into the high bits of
     * nonnegative levels. Match av_log_default_callback: compare, format, and
     * forward the base AV_LOG_* severity, since Crescendo carries severity as
     * structured data rather than terminal color. */
    if (level >= 0) {
        level &= 0xff;
    }
    /* av_log invokes the callback for every message regardless of level;
     * gating against av_log_get_level here mirrors the default callback. */
    if (level > av_log_get_level()) {
        return;
    }

    char line[1024];
    int print_prefix = 1;
    if (av_log_format_line2(avcl, level, fmt, vl, line, (int)sizeof(line), &print_prefix) < 0) {
        return;
    }

    size_t length = strnlen(line, sizeof(line));
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
        line[--length] = '\0';
    }
    if (length == 0) {
        return;
    }
    sink(level, line);
}

void crescendo_ffmpeg_install_log_sink(crescendo_ffmpeg_log_sink sink) {
    atomic_store_explicit(&g_sink, sink, memory_order_release);
    av_log_set_callback(sink != NULL ? crescendo_ffmpeg_log_trampoline : av_log_default_callback);
}

void crescendo_ffmpeg_emit_log(int level, const char *message) {
    if (message == NULL) {
        return;
    }
    av_log(NULL, level, "%s\n", message);
}
