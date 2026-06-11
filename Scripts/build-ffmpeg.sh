#!/bin/bash
#
# build-ffmpeg.sh - Builds FFmpeg as a macOS arm64 XCFramework for Crescendo.
#
# Output: build/artifacts/CFFmpeg.xcframework  (+ .zip + .checksum)
#
# FFmpeg is configured LGPL-only / audio-only (no GPL, no non-free, no HW
# accel), with HTTP(S) networking for streaming (TLS via Apple SecureTransport,
# so no OpenSSL/GnuTLS dependency). It is built static, then merged into a
# single dynamic library inside CFFmpeg.framework. Crescendo dynamically links
# to that framework - that is the LGPL boundary. The pin in upstream.lock,
# this script, and the shipped license text satisfy LGPL §6. Single-arch
# (macOS arm64); iOS / tvOS slices can be added later by parameterizing
# build_static_libs and create_framework on SDK + min-os.
#
# Supply-chain posture (fail-closed):
#   - The version comes from upstream.lock; the downloaded tarball must match
#     the recorded SHA-256 BEFORE extraction.
#   - The tarball's detached GPG signature is verified against the FFmpeg
#     release signing key committed at Keys/ffmpeg-signing-key.asc, always -
#     including unpinned --latest builds.
#   - The LGPL license text must exist in the source tree and inside the
#     published XCFramework, or the build fails.
#
# Usage: ./Scripts/build-ffmpeg.sh [--check-updates]
#   No arg            → builds the version pinned in upstream.lock. There is
#                       no override: changing what gets built means editing
#                       the lock in a reviewed commit.
#   --check-updates   → looks up the latest stable on ffmpeg.org, compares
#                       with the pin, and exits. Never downloads or builds.
#
# Updating the pin: set FFMPEG_VERSION in upstream.lock to the new version
# and clear FFMPEG_SHA256. The next run downloads, verifies the GPG
# signature, prints the tarball's SHA-256, and STOPS without building; adopt
# the printed hash into the lock and rerun.
#
# Environment:
#   SKIP_VERIFY=1              skips the post-build sibling `swift build`.
#   CRESCENDO_SIGN_IDENTITY    a Developer ID Application identity; when set,
#                              the published XCFramework is codesigned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${ROOT_DIR}/build/ffmpeg"
ARTIFACTS_DIR="${ROOT_DIR}/build/artifacts"
LOCK_FILE="${ROOT_DIR}/upstream.lock"
SIGNING_KEY="${ROOT_DIR}/Keys/ffmpeg-signing-key.asc"
LOG_FILE="${BUILD_DIR}/build.log"
FRAMEWORK_NAME="CFFmpeg"
MIN_MACOS="15.0"

# Resolved by resolve_version from upstream.lock, the only source of truth
# for what gets built. An empty hash means the pin is mid-update: the run
# verifies and reports the hash, then stops without building.
MODE="${1:-}"
FFMPEG_VERSION=""
EXPECTED_SHA256=""

# LGPL-only, audio-only configuration. No --enable-gpl, no --enable-nonfree.
# Everything is disabled, then audio decoders/demuxers are enabled explicitly.
CONFIGURE_FLAGS=(
    --enable-static
    --disable-shared
    --disable-debug
    --disable-programs
    --disable-doc
    --disable-htmlpages
    --disable-manpages
    --disable-podpages
    --disable-txtpages

    --disable-avdevice
    --disable-swscale
    --disable-avfilter
    --disable-encoders
    --disable-muxers
    --disable-bsfs
    --disable-devices
    --disable-filters

    # Networking for HTTP(S) audio streaming (internet radio, HLS). Still
    # LGPL-only: TLS uses Apple's SecureTransport (Security.framework), so no
    # OpenSSL/GnuTLS dependency. Only the protocols streaming needs are enabled.
    --enable-network
    --enable-securetransport
    --disable-protocols
    --enable-protocol=file
    --enable-protocol=http
    --enable-protocol=https
    --enable-protocol=tcp
    --enable-protocol=tls
    --enable-protocol=crypto
    --enable-protocol=data

    # --disable-videotoolbox is required separately from --disable-hwaccels:
    # FFmpeg's videotoolbox helper code isn't gated by --disable-hwaccels, so
    # without it we get unresolved CV*/VT* symbols. --disable-audiotoolbox is
    # belt-and-suspenders - we never enable audiotoolbox decoders by name.
    --disable-hwaccels
    --disable-videotoolbox
    --disable-audiotoolbox

    --disable-decoders
    --disable-demuxers

    # Audio decoders.
    --enable-decoder=flac
    --enable-decoder=alac
    --enable-decoder=ape
    --enable-decoder=wavpack
    --enable-decoder=tta
    --enable-decoder=tak
    --enable-decoder=shorten
    --enable-decoder=mpc7
    --enable-decoder=mpc8
    --enable-decoder=dsd_lsbf
    --enable-decoder=dsd_lsbf_planar
    --enable-decoder=dsd_msbf
    --enable-decoder=dsd_msbf_planar
    --enable-decoder=dst
    --enable-decoder=vorbis
    --enable-decoder=opus
    --enable-decoder=mp1
    --enable-decoder=mp1float
    --enable-decoder=mp2
    --enable-decoder=mp2float
    --enable-decoder=mp3
    --enable-decoder=mp3float
    --enable-decoder=aac
    --enable-decoder=aac_latm
    --enable-decoder=ac3
    --enable-decoder=eac3
    --enable-decoder=mlp
    --enable-decoder=truehd
    --enable-decoder=als
    --enable-decoder=pcm_s16le
    --enable-decoder=pcm_s24le
    --enable-decoder=pcm_s32le
    --enable-decoder=pcm_f32le
    --enable-decoder=pcm_f64le
    --enable-decoder=pcm_s16be
    --enable-decoder=pcm_s24be
    --enable-decoder=pcm_s32be
    --enable-decoder=pcm_f32be
    --enable-decoder=pcm_f64be
    --enable-decoder=pcm_alaw
    --enable-decoder=pcm_mulaw
    --enable-decoder=wmalossless
    --enable-decoder=wmapro
    --enable-decoder=wmav1
    --enable-decoder=wmav2
    --enable-decoder=wmavoice
    --enable-decoder=atrac1
    --enable-decoder=atrac3
    --enable-decoder=atrac3p
    --enable-decoder=dca

    # Container demuxers.
    --enable-demuxer=flac
    --enable-demuxer=wav
    --enable-demuxer=aiff
    --enable-demuxer=ogg
    --enable-demuxer=matroska
    --enable-demuxer=ape
    --enable-demuxer=wv
    --enable-demuxer=tta
    --enable-demuxer=tak
    --enable-demuxer=mp3
    --enable-demuxer=aac
    --enable-demuxer=ac3
    --enable-demuxer=eac3
    --enable-demuxer=mlp
    --enable-demuxer=truehd
    --enable-demuxer=mov
    --enable-demuxer=dsf
    --enable-demuxer=iff
    --enable-demuxer=mpc
    --enable-demuxer=mpc8
    --enable-demuxer=asf
    --enable-demuxer=pcm_s16le
    --enable-demuxer=pcm_s24le
    --enable-demuxer=pcm_s32le
    --enable-demuxer=pcm_f32le
    --enable-demuxer=pcm_f64le
    --enable-demuxer=caf
    --enable-demuxer=dts
    --enable-demuxer=w64
    --enable-demuxer=shorten

    # Streaming demuxers: HLS playlists and the MPEG-TS segments they carry.
    # Plain HTTP/ICY (Icecast/SHOUTcast) audio reuses the mp3/aac/ogg demuxers
    # already enabled above.
    --enable-demuxer=hls
    --enable-demuxer=mpegts
)

log()   { echo "==> $1"; }
error() { echo "ERROR: $1" >&2; exit 1; }

# Usage: run_logged "<label>" command args...
# Runs the command with stdout appended silently to LOG_FILE and stderr
# tee'd to both LOG_FILE and the terminal - so `make`'s per-recipe noise
# stays hidden but compiler warnings/errors are not missed. On a TTY, shows
# an inline animated spinner alongside the label; on non-TTY (CI, pipe)
# prints the label + newline and skips the animation.
run_logged() {
    local label="$1"
    shift

    if [[ -t 1 ]]; then
        printf '==> %s ' "$label"
    else
        printf '==> %s\n' "$label"
    fi

    "$@" >> "$LOG_FILE" 2> >(tee -a "$LOG_FILE" >&2) &
    local pid=$!

    if [[ -t 1 ]]; then
        local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
        local i=0
        while kill -0 "$pid" 2>/dev/null; do
            i=$(( (i + 1) % ${#spin[@]} ))
            printf '\r\033[K==> %s %s' "$label" "${spin[$i]}"
            sleep 0.1
        done
        printf '\r\033[K==> %s\n' "$label"
    fi

    wait "$pid"
}

# Looks up the latest stable on ffmpeg.org (highest ffmpeg-X.Y[.Z].tar.xz;
# the regex excludes -rc / -dev / snapshots), reports it against the pin,
# and exits. Discovery only; never downloads source or builds.
check_updates() {
    local lock_version
    lock_version="$(sed -n 's/^FFMPEG_VERSION=//p' "$LOCK_FILE" 2>/dev/null)"
    log "Pinned:  FFmpeg ${lock_version:-<none>}"
    local latest
    latest="$(curl -fsSL "https://ffmpeg.org/releases/" \
        | grep -oE 'ffmpeg-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz' \
        | sed -E 's/ffmpeg-(.*)\.tar\.xz/\1/' \
        | sort -V | tail -1)"
    log "Latest:  FFmpeg ${latest:-<lookup failed>}"
    if [ -n "$latest" ] && [ "$latest" != "$lock_version" ]; then
        log "Update available. To adopt: set FFMPEG_VERSION=${latest} in upstream.lock, clear FFMPEG_SHA256, and rerun this script."
    else
        log "Pin is current."
    fi
    exit 0
}

# Reads the pin from upstream.lock, the only source of truth for what gets
# built. A missing hash is the deliberate mid-update state: the run will
# verify what it can, report the hash to adopt, and stop without building.
resolve_version() {
    [ -f "$LOCK_FILE" ] || error "upstream.lock not found; the build refuses to run unpinned"
    FFMPEG_VERSION="$(sed -n 's/^FFMPEG_VERSION=//p' "$LOCK_FILE")"
    EXPECTED_SHA256="$(sed -n 's/^FFMPEG_SHA256=//p' "$LOCK_FILE")"
    [ -n "$FFMPEG_VERSION" ] || error "upstream.lock is missing FFMPEG_VERSION"
    if [ -n "$EXPECTED_SHA256" ]; then
        log "Building pinned FFmpeg ${FFMPEG_VERSION} (upstream.lock)"
    else
        log "FFMPEG_SHA256 is empty: pin-update mode. The tarball will be"
        log "downloaded and verified, its hash reported, and the build stopped."
    fi
}

# Verifies the downloaded tarball before anything extracts it: the detached
# GPG signature against the committed FFmpeg release signing key (always),
# and the SHA-256 against the lock pin (when pinned). Fail-closed.
verify_download() {
    local tarball="$1" sig="$2"

    [ -f "$SIGNING_KEY" ] || error "Missing ${SIGNING_KEY}; cannot verify the FFmpeg signature"
    log "Verifying GPG signature against Keys/ffmpeg-signing-key.asc..."
    local keyring
    keyring="$(mktemp -d)"
    chmod 700 "$keyring"
    GNUPGHOME="$keyring" gpg --quiet --import "$SIGNING_KEY" 2>/dev/null
    if ! GNUPGHOME="$keyring" gpg --quiet --verify "$sig" "$tarball" 2>/dev/null; then
        rm -rf "$keyring"
        error "GPG signature verification FAILED for ffmpeg-${FFMPEG_VERSION}.tar.xz. The download is not authentic; do not build from it."
    fi
    rm -rf "$keyring"
    log "  Signature: good (FFmpeg release signing key)"

    local actual
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [ -n "$EXPECTED_SHA256" ]; then
        if [ "$actual" != "$EXPECTED_SHA256" ]; then
            error "SHA-256 mismatch for ffmpeg-${FFMPEG_VERSION}.tar.xz:
       expected: ${EXPECTED_SHA256}
       actual:   ${actual}
The bytes do not match the reviewed pin; do not build from them."
        fi
        log "  SHA-256: matches upstream.lock"
    else
        # Pin-update mode: report the hash for adoption and stop. Nothing is
        # ever built from a hash that is not recorded in upstream.lock.
        log "  Signature verified. SHA-256 of the download:"
        log "      FFMPEG_SHA256=${actual}"
        rm -f "$tarball" "${tarball}.asc"
        error "Pin update incomplete: adopt the hash above into upstream.lock and rerun."
    fi
}

# Removes leftover state from prior multi-platform attempts so the new
# single-slice build cannot accidentally pick up stale x86_64 / iOS dylibs.
clean_stale_state() {
    rm -rf \
        "${BUILD_DIR}/install" \
        "${BUILD_DIR}/frameworks" \
        "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"
    find "$BUILD_DIR" -maxdepth 1 -name 'build-*' -exec rm -rf {} + 2>/dev/null || true
    find "$BUILD_DIR" -maxdepth 1 -name 'merged-*.dylib' -delete 2>/dev/null || true
}

download_ffmpeg() {
    local src_dir="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}"
    if [ -d "$src_dir" ]; then
        log "FFmpeg ${FFMPEG_VERSION} source already present (verified at download)"
        return
    fi
    log "Downloading FFmpeg ${FFMPEG_VERSION}..."
    mkdir -p "$BUILD_DIR"
    local tarball="${BUILD_DIR}/ffmpeg.tar.xz"
    curl -fL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
         -o "$tarball"
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc" \
         -o "${tarball}.asc"

    verify_download "$tarball" "${tarball}.asc"

    tar xf "$tarball" -C "$BUILD_DIR"
    rm "$tarball" "${tarball}.asc"
}

build_static_libs() {
    local prefix="${BUILD_DIR}/install/macos-arm64"
    local src_dir="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}"
    local work="${BUILD_DIR}/build-macos-arm64"

    rm -rf "$prefix" "$work"
    mkdir -p "$work"
    cd "$work"

    local cc sysroot
    cc="$(xcrun -sdk macosx -find clang)"
    sysroot="$(xcrun -sdk macosx --show-sdk-path)"

    run_logged "Configuring FFmpeg ${FFMPEG_VERSION} (macOS arm64, audio-only, LGPL)..." \
        "$src_dir/configure" \
        --prefix="$prefix" \
        --target-os=darwin \
        --arch=arm64 \
        --cc="$cc" \
        --extra-cflags="-arch arm64 -mmacosx-version-min=${MIN_MACOS} -isysroot ${sysroot}" \
        --extra-ldflags="-arch arm64 -mmacosx-version-min=${MIN_MACOS}" \
        --enable-cross-compile \
        --sysroot="$sysroot" \
        "${CONFIGURE_FLAGS[@]}"

    run_logged "Compiling..." make -j"$(sysctl -n hw.ncpu)"
    run_logged "Installing..." make install

    cd "$ROOT_DIR"
}

create_framework() {
    local prefix="${BUILD_DIR}/install/macos-arm64"
    local fw_root="${BUILD_DIR}/frameworks/macos-arm64/${FRAMEWORK_NAME}.framework"
    local versioned="$fw_root/Versions/A"

    rm -rf "$fw_root"
    mkdir -p "$versioned/Headers" "$versioned/Modules" "$versioned/Resources"

    log "Building ${FRAMEWORK_NAME}.framework..."

    local sdk_path
    sdk_path="$(xcrun -sdk macosx --show-sdk-path)"

    # -force_load on each archive pulls in every object file (FFmpeg modules
    # register codecs/demuxers via constructor symbols that ld would otherwise
    # strip as "unused").
    xcrun -sdk macosx clang \
        -arch arm64 \
        -mmacosx-version-min="${MIN_MACOS}" \
        -isysroot "$sdk_path" \
        -dynamiclib \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}" \
        -compatibility_version 1 \
        -current_version "${FFMPEG_VERSION%%.*}" \
        -Wl,-force_load,"${prefix}/lib/libavformat.a" \
        -Wl,-force_load,"${prefix}/lib/libavcodec.a" \
        -Wl,-force_load,"${prefix}/lib/libswresample.a" \
        -Wl,-force_load,"${prefix}/lib/libavutil.a" \
        -lz -lbz2 -liconv \
        -framework CoreFoundation \
        -framework AudioToolbox \
        -framework CoreMedia \
        -framework Security \
        -o "$versioned/${FRAMEWORK_NAME}"

    cp -R "${prefix}/include/"* "$versioned/Headers/"

    # FFmpeg headers use quoted includes that resolve relative to the file,
    # so libavformat/foo.h's `#include "libavcodec/bar.h"` doesn't resolve
    # until we help it. Two fixes:
    #
    # 1. Self-refs: rewrite `"libavutil/x.h"` → `"x.h"` inside each lib.
    #    A self-symlink (libavutil/libavutil → .) loops Xcode 17's SwiftBuild
    #    when it walks the framework, so we rewrite instead of symlinking.
    #
    # 2. Cross-lib refs: one-way symlinks along the dep graph only
    #    (libavformat → libavcodec/libavutil, libavcodec → libavutil,
    #    libswresample → libavutil). No reverse links → no cycles, walks
    #    terminate at libavutil.
    for lib in libavformat libavcodec libavutil libswresample; do
        if [ -d "$versioned/Headers/$lib" ]; then
            find "$versioned/Headers/$lib" -name '*.h' -type f -exec sed -i '' -E \
                "s|#include[[:space:]]*\"$lib/([^\"]+)\"|#include \"\\1\"|g" {} +
        fi
    done

    ln -s ../libavcodec    "$versioned/Headers/libavformat/libavcodec"
    ln -s ../libavutil     "$versioned/Headers/libavformat/libavutil"
    ln -s ../libavutil     "$versioned/Headers/libavcodec/libavutil"
    ln -s ../libavutil     "$versioned/Headers/libswresample/libavutil"

    cat > "$versioned/Headers/${FRAMEWORK_NAME}.h" << 'HEADER'
#ifndef CFFMPEG_H
#define CFFMPEG_H

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libswresample/swresample.h"

#endif /* CFFMPEG_H */
HEADER

    cat > "$versioned/Modules/module.modulemap" << MODULEMAP
framework module ${FRAMEWORK_NAME} [system] {
    umbrella header "${FRAMEWORK_NAME}.h"
    export *
    module * { export * }
}
MODULEMAP

    cat > "$versioned/Resources/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>org.Crescendo.${FRAMEWORK_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${FFMPEG_VERSION}</string>
    <key>CFBundleVersion</key><string>${FFMPEG_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>MinimumOSVersion</key><string>${MIN_MACOS}</string>
</dict>
</plist>
PLIST

    # LGPL distribution requirement: ship the license alongside the binary.
    # Fail-closed: an artifact without its license text is a compliance
    # regression, not a warning.
    [ -f "${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}/COPYING.LGPLv2.1" ] \
        || error "FFmpeg source tree has no COPYING.LGPLv2.1; refusing to build an artifact without its license text"
    cp "${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}/COPYING.LGPLv2.1" \
       "$versioned/Resources/COPYING.LGPLv2.1"

    # Standard macOS framework symlinks → Versions/Current.
    (cd "$fw_root/Versions" && ln -sfh A Current)
    (cd "$fw_root" \
        && ln -sfh "Versions/Current/${FRAMEWORK_NAME}" "${FRAMEWORK_NAME}" \
        && ln -sfh "Versions/Current/Headers"  "Headers" \
        && ln -sfh "Versions/Current/Modules"  "Modules" \
        && ln -sfh "Versions/Current/Resources" "Resources")
}

create_xcframework() {
    local fw="${BUILD_DIR}/frameworks/macos-arm64/${FRAMEWORK_NAME}.framework"
    local xcfw="${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"
    rm -rf "$xcfw"

    run_logged "Packaging XCFramework..." xcodebuild -create-xcframework \
        -framework "$fw" \
        -output "$xcfw"
}

publish() {
    mkdir -p "$ARTIFACTS_DIR"
    rm -rf "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"
    rm -f  "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework.zip" \
           "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework.checksum"

    log "Publishing to ${ARTIFACTS_DIR}..."
    cp -R "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework" "$ARTIFACTS_DIR/"

    # Post-build compliance gate: the license text must have survived into
    # the published artifact.
    [ -f "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework/macos-arm64/${FRAMEWORK_NAME}.framework/Resources/COPYING.LGPLv2.1" ] \
        || error "Published XCFramework is missing COPYING.LGPLv2.1"

    # Codesign the XCFramework when an identity is provided (Xcode 15+
    # surfaces and tracks binary-dependency signatures for consumers).
    # Unsigned remains valid: SwiftPM checksums protect the bytes, and the
    # consumer app re-signs embedded frameworks with its own identity.
    if [ -n "${CRESCENDO_SIGN_IDENTITY:-}" ]; then
        log "Codesigning with: ${CRESCENDO_SIGN_IDENTITY}"
        codesign --force --timestamp --sign "$CRESCENDO_SIGN_IDENTITY" \
            "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"
    else
        log "Artifact is unsigned (set CRESCENDO_SIGN_IDENTITY to codesign)"
    fi

    # -y preserves symlinks; SwiftPM computes the binary-target checksum
    # against the zip, so symlinks must round-trip.
    (cd "$ARTIFACTS_DIR" && zip -ry -q "${FRAMEWORK_NAME}.xcframework.zip" "${FRAMEWORK_NAME}.xcframework")

    local checksum
    checksum="$(swift package compute-checksum "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework.zip")"
    echo "$checksum" > "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework.checksum"

    log "  Checksum: ${checksum}"
}

# Exercises the new framework against the Crescendo engine source when its
# checkout sits beside this repo (the maintainer setup; the engine's local
# mode reads ../CrescendoKit/build/artifacts). Third parties building only
# the dependency artifacts skip this automatically. SKIP_VERIFY=1 to skip.
verify_swift_build() {
    if [ "${SKIP_VERIFY:-0}" = "1" ]; then
        log "SKIP_VERIFY=1 - skipping swift build verification"
        return
    fi
    local engine_dir="${ROOT_DIR}/../Crescendo"
    if [ ! -f "${engine_dir}/Package.swift" ]; then
        log "No sibling Crescendo checkout - skipping engine build verification"
        return
    fi
    cd "$engine_dir"
    export CRESCENDO_LOCAL_FFMPEG=1
    [ -d "${ARTIFACTS_DIR}/CTagLib.xcframework" ] && export CRESCENDO_LOCAL_TAGLIB=1
    if run_logged "Verifying with swift build (sibling Crescendo)..." swift build; then
        log "Prepared ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"
    else
        error "swift build failed - see ${LOG_FILE}"
    fi
}

main() {
    command -v xcrun  >/dev/null || error "Xcode command line tools not found"
    command -v swift  >/dev/null || error "swift not found in PATH"
    command -v curl   >/dev/null || error "curl not found in PATH"
    command -v gpg    >/dev/null || error "gpg not found; install it with: brew install gnupg (required to verify FFmpeg release signatures)"
    command -v shasum >/dev/null || error "shasum not found in PATH"

    log "FFmpeg XCFramework builder - macOS arm64, LGPL audio-only"
    [ "$MODE" = "--check-updates" ] && check_updates
    [ -z "$MODE" ] || error "Unknown argument '$MODE'. The build takes no version argument; edit upstream.lock to change what gets built (--check-updates to compare pins)."
    resolve_version
    log "FFmpeg ${FFMPEG_VERSION} -> ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"

    mkdir -p "$BUILD_DIR"
    : > "$LOG_FILE"
    log "Complete Build Log: ${LOG_FILE}"

    clean_stale_state
    download_ffmpeg
    build_static_libs
    create_framework
    create_xcframework
    publish
    verify_swift_build

    log "Done."
}

main "$@"
