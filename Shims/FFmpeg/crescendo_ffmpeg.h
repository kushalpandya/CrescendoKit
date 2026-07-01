/*
 * crescendo_ffmpeg.h - Crescendo's C shim over FFmpeg, part of CFFmpeg.
 * Carries what Swift cannot reach on its own: the av_log bridge and the
 * constants the Clang importer drops.
 *
 * FFmpeg writes its diagnostics through a process-global callback that
 * receives a printf format plus a va_list. Swift cannot define a
 * @convention(c) closure taking a va_list (CVaListPointer is not
 * representable in C), so the va_list must be rendered into a finished
 * line here in C. `crescendo_ffmpeg_install_log_sink` installs a trampoline
 * via av_log_set_callback that formats each message with
 * av_log_format_line2 and hands the Swift side a plain
 * (level, NUL-terminated line) pair, which IS representable.
 *
 * The trampoline is reentrant: a per-call stack buffer and a local
 * print_prefix, no locks on the log path. The tradeoff of the local
 * print_prefix is that a message FFmpeg emits in fragments (rare; almost
 * all messages are single complete lines) arrives as multiple prefixed
 * lines instead of one merged line. Messages above the level set with
 * av_log_set_level are dropped in the trampoline, matching the default
 * callback's gating.
 *
 * The sink is process-global, exactly like av_log_set_callback itself:
 * last writer wins. Passing NULL restores FFmpeg's default stderr callback.
 *
 * This header also re-exports, as typed constants, the FFmpeg macros the
 * Clang importer drops on the Swift side (function-like FFERRTAG expansions
 * and cast expressions do not import). Values are evaluated here, where the
 * real FFmpeg headers are visible, so they can never drift from upstream.
 * The HTTP family is diagnostic only: it lets the engine log or branch on
 * "404 vs connection refused" precisely; it widens no public error contract.
 */

#ifndef CRESCENDO_FFMPEG_H
#define CRESCENDO_FFMPEG_H

#include <stdint.h>

#include "libavutil/avutil.h"
#include "libavutil/error.h"

/* Marks the symbols exported from the framework. The shim is compiled with
 * -fvisibility=hidden, so only these entry points are added to CFFmpeg's
 * export list. */
#if defined(__GNUC__) || defined(__clang__)
#define CRESCENDO_FFMPEG_API __attribute__((visibility("default")))
#else
#define CRESCENDO_FFMPEG_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Receives one finished log line. `level` is the AV_LOG_* severity of the
 * message; `line` is a NUL-terminated, newline-trimmed rendering of the
 * message including FFmpeg's context prefix (e.g. "[aac @ 0x...] ...").
 * `line` is only valid for the duration of the call; copy it to keep it.
 * May be invoked concurrently from any FFmpeg thread.
 */
typedef void (*crescendo_ffmpeg_log_sink)(int level, const char *line);

/*
 * Routes FFmpeg's av_log stream to `sink` (replacing the default stderr
 * callback), or restores the default callback when `sink` is NULL. The
 * callback is process-global; the last installation wins.
 */
CRESCENDO_FFMPEG_API void crescendo_ffmpeg_install_log_sink(crescendo_ffmpeg_log_sink sink);

/*
 * Emits `message` (NUL-terminated, taken verbatim) through av_log at
 * `level`, from a NULL context. Exists because av_log is variadic and
 * Swift cannot call variadic C functions; used to exercise the sink
 * end-to-end from tests. A NULL message is ignored.
 */
CRESCENDO_FFMPEG_API void crescendo_ffmpeg_emit_log(int level, const char *message);

/*
 * FFmpeg constants the Clang importer cannot surface to Swift. AVERROR_*
 * values are the negative error codes FFmpeg calls return; compare, do not
 * negate. AV_LOG_* level macros are plain integer literals and import on
 * their own, so they are not duplicated here.
 */
static const int32_t CRESCENDO_AVERROR_EOF                = AVERROR_EOF;
static const int32_t CRESCENDO_AVERROR_EXIT               = AVERROR_EXIT;
static const int32_t CRESCENDO_AVERROR_INVALIDDATA        = AVERROR_INVALIDDATA;
static const int32_t CRESCENDO_AVERROR_PROTOCOL_NOT_FOUND = AVERROR_PROTOCOL_NOT_FOUND;

static const int32_t CRESCENDO_AVERROR_HTTP_BAD_REQUEST       = AVERROR_HTTP_BAD_REQUEST;
static const int32_t CRESCENDO_AVERROR_HTTP_UNAUTHORIZED      = AVERROR_HTTP_UNAUTHORIZED;
static const int32_t CRESCENDO_AVERROR_HTTP_FORBIDDEN         = AVERROR_HTTP_FORBIDDEN;
static const int32_t CRESCENDO_AVERROR_HTTP_NOT_FOUND         = AVERROR_HTTP_NOT_FOUND;
static const int32_t CRESCENDO_AVERROR_HTTP_TOO_MANY_REQUESTS = AVERROR_HTTP_TOO_MANY_REQUESTS;
static const int32_t CRESCENDO_AVERROR_HTTP_OTHER_4XX         = AVERROR_HTTP_OTHER_4XX;
static const int32_t CRESCENDO_AVERROR_HTTP_SERVER_ERROR      = AVERROR_HTTP_SERVER_ERROR;

/* The sentinel FFmpeg uses for an absent timestamp ((int64_t)0x8000000000000000). */
static const int64_t CRESCENDO_AV_NOPTS_VALUE = AV_NOPTS_VALUE;

#ifdef __cplusplus
}
#endif

#endif /* CRESCENDO_FFMPEG_H */
