#!/bin/bash
#
# build-ffmpeg.sh - Builds FFmpeg as a macOS universal (arm64 + x86_64)
# XCFramework for Crescendo.
#
# Output: build/artifacts/CFFmpeg.xcframework  (+ .zip + .checksum)
#
# FFmpeg is configured LGPL-only / audio-only (no GPL, no non-free, no HW
# accel), with HTTP(S) networking for streaming (TLS via Apple SecureTransport,
# so no OpenSSL/GnuTLS dependency). It is built static, then merged into a
# single dynamic library inside CFFmpeg.framework. Crescendo dynamically links
# to that framework - that is the LGPL boundary. The pin in upstream.lock,
# this script, and the shipped license text satisfy LGPL §6. FFmpeg's configure
# is single-arch, so each macOS arch is built and installed separately, then
# lipo'd into one universal framework binary. iOS / tvOS slices can be added
# later by parameterizing build_static_libs and create_framework on SDK + min-os.
# Building the x86_64 slice assembles FFmpeg's SIMD with nasm (brew install nasm).
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
MIN_MACOS="14.0"

# Crescendo's C shim over FFmpeg (see its header for the design): the av_log
# bridge (FFmpeg's log callback takes a va_list, which Swift cannot receive,
# so the formatting lives in C) plus constants the Clang importer drops. The
# code links into the framework dylib; the header ships as part of the
# framework's public surface, mirroring the CTagLib shim pattern.
SHIM_DIR="${ROOT_DIR}/Shims/FFmpeg"

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
    --enable-decoder=speex
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

# Removes leftover state from prior builds so a new build cannot pick up stale
# per-arch install trees, merged dylibs, or frameworks.
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

# Configures, compiles, and installs the static libs for a single arch ($1,
# arm64 or x86_64) under install/macos-<arch>. FFmpeg cannot emit a fat build
# from one configure pass, so this runs once per arch; the slices are merged in
# create_framework. --enable-cross-compile keeps configure from running the
# compiled probes (it cannot execute the x86_64 ones on an arm64 host, and the
# arm64 path has always used it too), relying on compile/link tests instead.
build_static_libs() {
    local arch="$1"
    local prefix="${BUILD_DIR}/install/macos-${arch}"
    local src_dir="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}"
    local work="${BUILD_DIR}/build-macos-${arch}"

    rm -rf "$prefix" "$work"
    mkdir -p "$work"
    cd "$work"

    local cc sysroot
    cc="$(xcrun -sdk macosx -find clang)"
    sysroot="$(xcrun -sdk macosx --show-sdk-path)"

    # -Wno-deprecated-declarations silences the upstream SecureTransport warnings
    # from tls_securetransport.c (deprecated since 10.15, but enabled on purpose
    # to keep TLS dependency-free for LGPL).
    run_logged "Configuring FFmpeg ${FFMPEG_VERSION} (macOS ${arch}, audio-only, LGPL)..." \
        "$src_dir/configure" \
        --prefix="$prefix" \
        --target-os=darwin \
        --arch="${arch}" \
        --cc="$cc" \
        --extra-cflags="-arch ${arch} -mmacosx-version-min=${MIN_MACOS} -isysroot ${sysroot} -Wno-deprecated-declarations" \
        --extra-ldflags="-arch ${arch} -mmacosx-version-min=${MIN_MACOS}" \
        --enable-cross-compile \
        --sysroot="$sysroot" \
        "${CONFIGURE_FLAGS[@]}"

    # The selective build leaves one conditionally unused raw-data helper, and
    # Apple Clang does not recognize two upstream fallthrough spellings. FFmpeg
    # adds -Wall and -Wimplicit-fallthrough after --extra-cflags, so append the
    # narrow suppressions to generated build state where they take precedence.
    # This applies only to upstream FFmpeg; the shim is compiled separately.
    printf '%s\n' \
        'CFLAGS += -Wno-unused-function -Wno-implicit-fallthrough' \
        >> ffbuild/config.mak

    run_logged "Compiling (${arch})..." make -j"$(sysctl -n hw.ncpu)"
    run_logged "Installing (${arch})..." make install

    cd "$ROOT_DIR"
}

# Links the four static FFmpeg libs under prefix $2 into a single-arch dynamic
# library at $3 for arch $1. -force_load on each archive pulls in every object
# file (FFmpeg modules register codecs/demuxers via constructor symbols that ld
# would otherwise strip as "unused"). -Wl,-x drops local symbols (internal
# backtrace names) from the symbol table; exported symbols stay, so the engine
# still links every codec it uses, just with a smaller binary.
link_framework_slice() {
    local arch="$1" prefix="$2" out="$3" sdk_path
    sdk_path="$(xcrun -sdk macosx --show-sdk-path)"

    local linker_warning_flag=""
    if [ "$arch" = "x86_64" ]; then
        # NASM's Mach-O backend cannot emit LC_BUILD_VERSION, and Apple's
        # linker has no warning-specific suppression for those assembly
        # objects. Limit -w to this one final x86_64 link; compilation, shim
        # warnings, and the arm64 link remain fully visible.
        linker_warning_flag="-Wl,-w"
    fi

    # Compile the av_log shim against this slice's installed FFmpeg headers;
    # its object joins the link below. Hidden visibility keeps everything but
    # the CRESCENDO_FFMPEG_API entry points out of the export list (FFmpeg's
    # own exports are unaffected; they come from the static archives).
    local shim_work="${BUILD_DIR}/build-shim"
    local shim_obj="${shim_work}/crescendo_ffmpeg-${arch}.o"
    mkdir -p "$shim_work"
    xcrun -sdk macosx clang \
        -c "${SHIM_DIR}/crescendo_ffmpeg.c" \
        -o "$shim_obj" \
        -arch "$arch" \
        -mmacosx-version-min="${MIN_MACOS}" \
        -isysroot "$sdk_path" \
        -I"${prefix}/include" \
        -O2 \
        -fstack-protector-strong \
        -fvisibility=hidden \
        -D_FORTIFY_SOURCE=2

    xcrun -sdk macosx clang \
        -arch "$arch" \
        -mmacosx-version-min="${MIN_MACOS}" \
        -isysroot "$sdk_path" \
        -dynamiclib \
        ${linker_warning_flag:+$linker_warning_flag} \
        -Wl,-x \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}" \
        -compatibility_version 1 \
        -current_version "${FFMPEG_VERSION%%.*}" \
        "$shim_obj" \
        -Wl,-force_load,"${prefix}/lib/libavformat.a" \
        -Wl,-force_load,"${prefix}/lib/libavcodec.a" \
        -Wl,-force_load,"${prefix}/lib/libswresample.a" \
        -Wl,-force_load,"${prefix}/lib/libavutil.a" \
        -lz -lbz2 -liconv \
        -framework CoreFoundation \
        -framework AudioToolbox \
        -framework CoreMedia \
        -framework Security \
        -o "$out"
}

create_framework() {
    local arm_prefix="${BUILD_DIR}/install/macos-arm64"
    local x86_prefix="${BUILD_DIR}/install/macos-x86_64"
    local fw_root="${BUILD_DIR}/frameworks/macos-arm64_x86_64/${FRAMEWORK_NAME}.framework"
    local versioned="$fw_root/Versions/A"

    rm -rf "$fw_root"
    mkdir -p "$versioned/Headers" "$versioned/Modules" "$versioned/Resources"

    log "Building ${FRAMEWORK_NAME}.framework (universal arm64 + x86_64)..."

    # Link each arch separately from its own static libs, then lipo the two
    # single-arch dylibs into one fat framework binary.
    local arm_dylib="${BUILD_DIR}/merged-arm64.dylib"
    local x86_dylib="${BUILD_DIR}/merged-x86_64.dylib"
    link_framework_slice arm64  "$arm_prefix" "$arm_dylib"
    link_framework_slice x86_64 "$x86_prefix" "$x86_dylib"
    lipo -create "$arm_dylib" "$x86_dylib" -output "$versioned/${FRAMEWORK_NAME}"
    rm -f "$arm_dylib" "$x86_dylib"

    # Public headers are arch-independent (avconfig.h is identical for both
    # little-endian 64-bit arches), so either install tree serves.
    cp -R "${arm_prefix}/include/"* "$versioned/Headers/"

    # The av_log shim header ships beside FFmpeg's own headers; its quoted
    # libavutil includes resolve against the sibling directories in place.
    cp "${SHIM_DIR}/crescendo_ffmpeg.h" "$versioned/Headers/crescendo_ffmpeg.h"

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
#include "libavutil/log.h"
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libswresample/swresample.h"
#include "crescendo_ffmpeg.h"

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
    local fw="${BUILD_DIR}/frameworks/macos-arm64_x86_64/${FRAMEWORK_NAME}.framework"
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
    [ -f "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework/macos-arm64_x86_64/${FRAMEWORK_NAME}.framework/Resources/COPYING.LGPLv2.1" ] \
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
    command -v nasm   >/dev/null || error "nasm not found; install it with: brew install nasm (required to assemble FFmpeg's x86_64 SIMD for the universal build)"

    log "FFmpeg XCFramework builder - macOS universal (arm64 + x86_64), LGPL audio-only"
    [ "$MODE" = "--check-updates" ] && check_updates
    [ -z "$MODE" ] || error "Unknown argument '$MODE'. The build takes no version argument; edit upstream.lock to change what gets built (--check-updates to compare pins)."
    resolve_version
    log "FFmpeg ${FFMPEG_VERSION} -> ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"

    mkdir -p "$BUILD_DIR"
    : > "$LOG_FILE"
    log "Complete Build Log: ${LOG_FILE}"

    clean_stale_state
    download_ffmpeg
    build_static_libs arm64
    build_static_libs x86_64
    create_framework
    create_xcframework
    publish
    verify_swift_build

    log "Done."
}

main "$@"
