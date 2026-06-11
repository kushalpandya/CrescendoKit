#!/bin/bash
#
# build-taglib.sh - Builds TagLib + the CTagLib C shim as a macOS arm64
# dynamic XCFramework for Crescendo.
#
# Output: build/artifacts/CTagLib.xcframework  (+ .zip + .checksum)
#
# This mirrors build-ffmpeg.sh: it downloads upstream source, compiles it
# static, and merges it into a single dynamic library inside a .framework that
# Crescendo links via @rpath. The difference is the source - TagLib is C++, so
# we also compile the thin `extern "C"` shim in Shims/TagLib/ctaglib.cpp and
# link it in. The framework exports ONLY the shim's C API (everything is compiled with
# -fvisibility=hidden; the shim functions are marked CTAGLIB_API), so TagLib's
# C++ symbols stay private and cannot clash with a host app that links its own
# copy of TagLib.
#
# TagLib is dual LGPL 2.1 / MPL 1.1; Crescendo elects MPL. Dynamic linking plus
# the shipped COPYING.MPL satisfy that election. CMake (brew install cmake) is
# used to build TagLib; it is a build-time tool for this script only, never a
# `swift build` dependency.
#
# Supply-chain posture (fail-closed):
#   - The version comes from upstream.lock; the downloaded tarball must match
#     the recorded SHA-256 BEFORE extraction. TagLib publishes no release
#     signatures, so the hash pin is the integrity anchor (recorded once,
#     reviewed, then enforced on every build).
#   - The MPL license text must exist in the source tree and inside the
#     published XCFramework, or the build fails.
#
# Usage: ./Scripts/build-taglib.sh [--check-updates]
#   No arg            → builds the version pinned in upstream.lock. There is
#                       no override: changing what gets built means editing
#                       the lock in a reviewed commit.
#   --check-updates   → looks up the latest stable on GitHub, compares with
#                       the pin, and exits. Never downloads or builds.
#
# Updating the pin: set TAGLIB_VERSION in upstream.lock to the new version
# and clear TAGLIB_SHA256. The next run downloads, prints the tarball's
# SHA-256, and STOPS without building; adopt the printed hash into the lock
# and rerun.
#
# Environment:
#   SKIP_VERIFY=1              skips the post-build sibling `swift build`.
#   CRESCENDO_SIGN_IDENTITY    a Developer ID Application identity; when set,
#                              the published XCFramework is codesigned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${ROOT_DIR}/build/taglib"
ARTIFACTS_DIR="${ROOT_DIR}/build/artifacts"
SHIM_DIR="${ROOT_DIR}/Shims/TagLib"
LOCK_FILE="${ROOT_DIR}/upstream.lock"
LOG_FILE="${BUILD_DIR}/build.log"
FRAMEWORK_NAME="CTagLib"
MIN_MACOS="15.0"

# Resolved by resolve_version from upstream.lock, the only source of truth
# for what gets built. An empty hash means the pin is mid-update: the run
# reports the hash, then stops without building.
MODE="${1:-}"
TAGLIB_VERSION=""
EXPECTED_SHA256=""

# Hardening applied to BOTH TagLib and the shim. The framework is built by this
# script (not the SwiftPM manifest), so these flags are free of the manifest's
# `unsafeFlags` restriction. -fvisibility=hidden hides TagLib's symbols;
# -D_FORTIFY_SOURCE=2 needs optimization, which the Release build supplies.
HARDENING_FLAGS=(
    -fstack-protector-strong
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -D_FORTIFY_SOURCE=2
)

log()   { echo "==> $1"; }
error() { echo "ERROR: $1" >&2; exit 1; }

# Usage: run_logged "<label>" command args...
# Runs the command with stdout appended silently to LOG_FILE and stderr tee'd to
# both LOG_FILE and the terminal. On a TTY shows an inline spinner; on non-TTY
# prints the label and skips the animation. Mirrors build-ffmpeg.sh.
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

# Locates cmake, preferring Homebrew's copy (the Xcode toolchain does not ship
# one). Needed only to build TagLib here, never at swift-build time.
find_cmake() {
    if command -v cmake >/dev/null; then
        CMAKE="$(command -v cmake)"
    elif [ -x /opt/homebrew/bin/cmake ]; then
        CMAKE="/opt/homebrew/bin/cmake"
    else
        error "cmake not found. Install it with: brew install cmake"
    fi
}

# Looks up the latest stable by following the GitHub /releases/latest
# redirect (-> /releases/tag/v<version>; taglib.org serves no directory
# index, and this redirect is the canonical "latest non-prerelease"
# pointer), reports it against the pin, and exits. Discovery only.
check_updates() {
    local lock_version
    lock_version="$(sed -n 's/^TAGLIB_VERSION=//p' "$LOCK_FILE" 2>/dev/null)"
    log "Pinned:  TagLib ${lock_version:-<none>}"
    local final_url latest
    final_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/taglib/taglib/releases/latest")"
    latest="$(printf '%s\n' "$final_url" | sed -E 's|.*/tag/v?||')"
    log "Latest:  TagLib ${latest:-<lookup failed>}"
    if [ -n "$latest" ] && [ "$latest" != "$lock_version" ]; then
        log "Update available. To adopt: set TAGLIB_VERSION=${latest} in upstream.lock, clear TAGLIB_SHA256, and rerun this script."
    else
        log "Pin is current."
    fi
    exit 0
}

# Reads the pin from upstream.lock, the only source of truth for what gets
# built. A missing hash is the deliberate mid-update state: the run will
# report the hash to adopt and stop without building.
resolve_version() {
    [ -f "$LOCK_FILE" ] || error "upstream.lock not found; the build refuses to run unpinned"
    TAGLIB_VERSION="$(sed -n 's/^TAGLIB_VERSION=//p' "$LOCK_FILE")"
    EXPECTED_SHA256="$(sed -n 's/^TAGLIB_SHA256=//p' "$LOCK_FILE")"
    [ -n "$TAGLIB_VERSION" ] || error "upstream.lock is missing TAGLIB_VERSION"
    if [ -n "$EXPECTED_SHA256" ]; then
        log "Building pinned TagLib ${TAGLIB_VERSION} (upstream.lock)"
    else
        log "TAGLIB_SHA256 is empty: pin-update mode. The tarball will be"
        log "downloaded, its hash reported, and the build stopped."
    fi
}

# Verifies the downloaded tarball's SHA-256 against the lock pin before
# anything extracts it. Fail-closed when pinned; compute-and-report when not.
verify_download() {
    local tarball="$1"
    local actual
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [ -n "$EXPECTED_SHA256" ]; then
        if [ "$actual" != "$EXPECTED_SHA256" ]; then
            error "SHA-256 mismatch for taglib-${TAGLIB_VERSION}.tar.gz:
       expected: ${EXPECTED_SHA256}
       actual:   ${actual}
The bytes do not match the reviewed pin; do not build from them."
        fi
        log "  SHA-256: matches upstream.lock"
    else
        # Pin-update mode: report the hash for adoption and stop. Nothing is
        # ever built from a hash that is not recorded in upstream.lock.
        log "  SHA-256 of the download:"
        log "      TAGLIB_SHA256=${actual}"
        rm -f "$tarball"
        error "Pin update incomplete: adopt the hash above into upstream.lock and rerun."
    fi
}

# Removes leftover state from prior builds so a new build cannot pick up stale
# install trees or frameworks.
clean_stale_state() {
    rm -rf \
        "${BUILD_DIR}/install" \
        "${BUILD_DIR}/cmake-build" \
        "${BUILD_DIR}/framework-build" \
        "${BUILD_DIR}/frameworks" \
        "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"
}

download_taglib() {
    SRC_DIR="${BUILD_DIR}/taglib-${TAGLIB_VERSION}"
    if [ -d "$SRC_DIR" ]; then
        log "TagLib ${TAGLIB_VERSION} source already present"
        return
    fi
    log "Downloading TagLib ${TAGLIB_VERSION}..."
    mkdir -p "$BUILD_DIR"
    # GitHub release asset: tag is v<version>, asset is taglib-<version>.tar.gz.
    # -L follows the 302 to the presigned asset URL.
    curl -fL "https://github.com/taglib/taglib/releases/download/v${TAGLIB_VERSION}/taglib-${TAGLIB_VERSION}.tar.gz" \
         -o "${BUILD_DIR}/taglib.tar.gz"

    verify_download "${BUILD_DIR}/taglib.tar.gz"

    tar xf "${BUILD_DIR}/taglib.tar.gz" -C "$BUILD_DIR"
    rm "${BUILD_DIR}/taglib.tar.gz"
    [ -d "$SRC_DIR" ] || error "Extraction did not produce ${SRC_DIR}"
}

# Builds a static libtag.a (Release, arm64, hidden visibility, hardened) and
# installs it plus the public headers under build/taglib/install.
build_taglib() {
    PREFIX="${BUILD_DIR}/install"
    local cmake_build="${BUILD_DIR}/cmake-build"
    rm -rf "$PREFIX" "$cmake_build"

    run_logged "Configuring TagLib ${TAGLIB_VERSION} (cmake, static, arm64, hardened)..." \
        "$CMAKE" -S "$SRC_DIR" -B "$cmake_build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_BINDINGS=OFF \
        -DBUILD_TESTING=OFF \
        -DWITH_ZLIB=ON \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_MACOS}" \
        -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
        -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
        -DCMAKE_CXX_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX"

    run_logged "Compiling TagLib..." "$CMAKE" --build "$cmake_build" -j"$(sysctl -n hw.ncpu)"
    run_logged "Installing TagLib..." "$CMAKE" --install "$cmake_build"

    [ -f "${PREFIX}/lib/libtag.a" ] || error "TagLib build did not produce libtag.a"
}

# Compiles the C shim and links it with libtag.a into the dynamic framework
# binary. Only the CTAGLIB_API-marked C functions are exported.
create_framework() {
    local fw_root="${BUILD_DIR}/frameworks/${FRAMEWORK_NAME}.framework"
    local versioned="$fw_root/Versions/A"
    local work="${BUILD_DIR}/framework-build"

    rm -rf "$fw_root" "$work"
    mkdir -p "$versioned/Headers" "$versioned/Modules" "$versioned/Resources" "$work"

    log "Building ${FRAMEWORK_NAME}.framework..."

    local sysroot
    sysroot="$(xcrun -sdk macosx --show-sdk-path)"

    # Compile the shim against TagLib's installed headers.
    xcrun -sdk macosx clang++ \
        -c "${SHIM_DIR}/ctaglib.cpp" \
        -o "${work}/ctaglib.o" \
        -std=c++17 \
        -arch arm64 \
        -mmacosx-version-min="${MIN_MACOS}" \
        -isysroot "$sysroot" \
        -I"${SHIM_DIR}" \
        -I"${PREFIX}/include/taglib" \
        -DTAGLIB_STATIC \
        -O2 \
        "${HARDENING_FLAGS[@]}"

    # Link the shim + TagLib into one dynamic library. libc++ and libz are
    # dynamic system libraries. FileRef references every format parser directly,
    # so the normal link pulls them all in (full format coverage).
    xcrun -sdk macosx clang++ \
        -dynamiclib \
        -arch arm64 \
        -mmacosx-version-min="${MIN_MACOS}" \
        -isysroot "$sysroot" \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}" \
        -compatibility_version 1 \
        -current_version "${TAGLIB_VERSION%%.*}" \
        "${work}/ctaglib.o" \
        "${PREFIX}/lib/libtag.a" \
        -lz \
        -o "$versioned/${FRAMEWORK_NAME}"

    # Public surface: only the C shim header.
    cp "${SHIM_DIR}/ctaglib.h" "$versioned/Headers/ctaglib.h"

    cat > "$versioned/Modules/module.modulemap" << MODULEMAP
framework module ${FRAMEWORK_NAME} {
    header "ctaglib.h"
    export *
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
    <key>CFBundleShortVersionString</key><string>${TAGLIB_VERSION}</string>
    <key>CFBundleVersion</key><string>${TAGLIB_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>MinimumOSVersion</key><string>${MIN_MACOS}</string>
</dict>
</plist>
PLIST

    # MPL election: ship TagLib's MPL license text alongside the binary.
    # Fail-closed: an artifact without its license text is a compliance
    # regression, not a warning.
    [ -f "${SRC_DIR}/COPYING.MPL" ] \
        || error "TagLib source tree has no COPYING.MPL; refusing to build an artifact without its license text"
    cp "${SRC_DIR}/COPYING.MPL" "$versioned/Resources/COPYING.MPL"

    # Standard macOS framework symlinks → Versions/Current.
    (cd "$fw_root/Versions" && ln -sfh A Current)
    (cd "$fw_root" \
        && ln -sfh "Versions/Current/${FRAMEWORK_NAME}" "${FRAMEWORK_NAME}" \
        && ln -sfh "Versions/Current/Headers"  "Headers" \
        && ln -sfh "Versions/Current/Modules"  "Modules" \
        && ln -sfh "Versions/Current/Resources" "Resources")
}

create_xcframework() {
    local fw="${BUILD_DIR}/frameworks/${FRAMEWORK_NAME}.framework"
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
    [ -f "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework/macos-arm64/${FRAMEWORK_NAME}.framework/Resources/COPYING.MPL" ] \
        || error "Published XCFramework is missing COPYING.MPL"

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

    # -y preserves symlinks; SwiftPM computes the binary-target checksum against
    # the zip, so symlinks must round-trip.
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
    # Use the local CTagLib we just built; also use a local CFFmpeg if one is
    # present so the verify does not trigger a remote fetch mid-build.
    export CRESCENDO_LOCAL_TAGLIB=1
    [ -d "${ARTIFACTS_DIR}/CFFmpeg.xcframework" ] && export CRESCENDO_LOCAL_FFMPEG=1
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
    command -v shasum >/dev/null || error "shasum not found in PATH"
    find_cmake

    log "TagLib XCFramework builder - macOS arm64, dynamic, MPL"
    [ "$MODE" = "--check-updates" ] && check_updates
    [ -z "$MODE" ] || error "Unknown argument '$MODE'. The build takes no version argument; edit upstream.lock to change what gets built (--check-updates to compare pins)."
    resolve_version
    log "TagLib ${TAGLIB_VERSION} -> ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"

    mkdir -p "$BUILD_DIR"
    : > "$LOG_FILE"
    log "Complete Build Log: ${LOG_FILE}"

    clean_stale_state
    download_taglib
    build_taglib
    create_framework
    create_xcframework
    publish
    verify_swift_build

    log "Done."
}

main "$@"
