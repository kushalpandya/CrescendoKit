/*
 * ctaglib.h - C-API shim over TagLib (C++), the public surface of CTagLib.
 *
 * TagLib is C++, which Swift cannot consume directly, so this thin `extern "C"`
 * surface bridges it. CTagLib ships as a dynamic framework (Scripts/build-taglib.sh)
 * built with hidden visibility; only the functions marked CTAGLIB_API below are
 * exported, so all of TagLib's C++ symbols stay private to the framework and
 * cannot clash with a host app that links its own copy of TagLib. The Swift
 * side imports only this header (no C++ interop).
 *
 * Design: `ctaglib_read` parses a file once into an opaque, heap-allocated
 * `ctaglib_metadata` handle that OWNS copies of every value. Accessors return
 * borrowed pointers into that owned storage, valid until `ctaglib_metadata_free`.
 * Nothing points back into transient TagLib objects, so there is no use-after-free
 * once the file is closed.
 *
 * The bulk of the tags is exposed as the raw TagLib PropertyMap - the full,
 * unified key/value dictionary (TITLE, ARTIST, ALBUM, REPLAYGAIN_TRACK_GAIN, ...)
 * that TagLib normalizes across every container format. The Swift layer picks
 * the curated fields out of it; nothing is dropped, so callers that fuzzy-match
 * extra keys see everything. Audio properties, attached pictures, and the
 * ID3v2 POPM rating need format-specific access and have dedicated accessors.
 *
 * Strings are LENGTH-DELIMITED (`const char*` + a `size_t*` out-length), never
 * NUL-terminated: tag values can carry embedded NULs or non-UTF-8 bytes. The
 * caller must use the returned length, not strlen, and validate UTF-8 itself.
 *
 * Concurrency: every call allocates its own handle and touches no shared state,
 * so the API is reentrant - safe to call concurrently across a library scan.
 *
 * This shim parses UNTRUSTED input (arbitrary library files). Every entry point
 * is exception-safe and returns a null/zero sentinel on failure rather than a
 * partial result; every index accessor bounds-checks.
 */

#ifndef CTAGLIB_H
#define CTAGLIB_H

#include <stddef.h>

/* Marks the symbols exported from the framework. The framework is compiled with
 * -fvisibility=hidden, so without this every C entry point would be hidden too
 * and the dynamic library would export nothing. */
#if defined(__GNUC__) || defined(__clang__)
#define CTAGLIB_API __attribute__((visibility("default")))
#else
#define CTAGLIB_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to one file's parsed metadata. */
typedef struct ctaglib_metadata ctaglib_metadata;

/*
 * Parses the audio file at `path` (a UTF-8, NUL-terminated filesystem path).
 * Returns a handle the caller must release with `ctaglib_metadata_free`, or
 * NULL if `path` is NULL or the file cannot be opened or recognized.
 */
CTAGLIB_API ctaglib_metadata *ctaglib_read(const char *path);

/* Releases a handle from `ctaglib_read`. Passing NULL is a no-op. */
CTAGLIB_API void ctaglib_metadata_free(ctaglib_metadata *meta);

/* ---- Audio properties (0 when unknown) ---- */

/* Duration in seconds. */
CTAGLIB_API double ctaglib_length_seconds(const ctaglib_metadata *meta);

/* Sample rate in hertz. */
CTAGLIB_API int ctaglib_sample_rate(const ctaglib_metadata *meta);

/* Channel count. */
CTAGLIB_API int ctaglib_channels(const ctaglib_metadata *meta);

/* Average bitrate in kilobits per second (TagLib's native unit). */
CTAGLIB_API int ctaglib_bitrate_kbps(const ctaglib_metadata *meta);

/* Bits per sample, for lossless formats that report it (0 otherwise). */
CTAGLIB_API int ctaglib_bits_per_sample(const ctaglib_metadata *meta);

/*
 * Whether the codec is lossless, determined from the actually-decoded codec
 * (not the file extension): 1 = lossless, 0 = lossy, -1 = unknown. Correctly
 * distinguishes ALAC from AAC in .m4a, WMA Lossless from lossy WMA, and
 * lossless WavPack from its hybrid-lossy mode.
 */
CTAGLIB_API int ctaglib_is_lossless(const ctaglib_metadata *meta);

/*
 * A short, lowercased codec/format name derived from the parsed file type
 * (e.g. "mp3", "flac", "alac", "aac", "vorbis", "opus", "wav", "aiff", "ape",
 * "wavpack", "tta", "musepack", "dsf", "dsdiff", "wma"), or NULL when the type
 * is not one of those. Borrowed, length-delimited; `out_len` must not be NULL.
 */
CTAGLIB_API const char *ctaglib_codec(const ctaglib_metadata *meta, size_t *out_len);

/* ---- Raw tag dictionary (TagLib PropertyMap) ---- */

/* The number of distinct tag keys. */
CTAGLIB_API size_t ctaglib_tag_count(const ctaglib_metadata *meta);

/*
 * The key at index `i` (0-based, `i < ctaglib_tag_count`) as a borrowed,
 * length-delimited UTF-8 buffer, or NULL if `i` is out of range. `out_len`
 * must not be NULL.
 */
CTAGLIB_API const char *ctaglib_tag_key(const ctaglib_metadata *meta, size_t i, size_t *out_len);

/* The number of values held under the key at index `i` (a tag may be
 * multi-valued), or 0 if `i` is out of range. */
CTAGLIB_API size_t ctaglib_tag_value_count(const ctaglib_metadata *meta, size_t i);

/*
 * Value `j` of the key at index `i` as a borrowed, length-delimited UTF-8
 * buffer, or NULL if either index is out of range. `out_len` must not be NULL.
 */
CTAGLIB_API const char *ctaglib_tag_value(const ctaglib_metadata *meta, size_t i, size_t j, size_t *out_len);

/* ---- Attached pictures ---- */

/* The number of embedded pictures. */
CTAGLIB_API size_t ctaglib_picture_count(const ctaglib_metadata *meta);

/*
 * The raw encoded bytes (PNG/JPEG/...) of picture `i`, or NULL if `i` is out of
 * range. Borrowed, length-delimited via `out_len` (which must not be NULL).
 */
CTAGLIB_API const unsigned char *ctaglib_picture_data(const ctaglib_metadata *meta, size_t i, size_t *out_len);

/*
 * The MIME type of picture `i` (e.g. "image/jpeg") as a borrowed,
 * length-delimited UTF-8 buffer, or NULL if `i` is out of range or the MIME
 * type is absent. `out_len` must not be NULL.
 */
CTAGLIB_API const char *ctaglib_picture_mime(const ctaglib_metadata *meta, size_t i, size_t *out_len);

/* ---- Rating (ID3v2 POPM) ---- */

/* Nonzero if the file carries an ID3v2 POPM rating. */
CTAGLIB_API int ctaglib_has_rating(const ctaglib_metadata *meta);

/*
 * The raw POPM rating byte (0-255) when `ctaglib_has_rating` is nonzero, else 0.
 * Other rating conventions (e.g. Vorbis RATING / FMPS_RATING) surface through
 * the raw tag dictionary instead.
 */
CTAGLIB_API int ctaglib_rating(const ctaglib_metadata *meta);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CTAGLIB_H */
