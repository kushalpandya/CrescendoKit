#!/bin/bash
#
# build-taglib.sh - Builds TagLib + the CTagLib C shim as a macOS universal
# (arm64 + x86_64) STATIC XCFramework: the build input the Crescendo engine
# folds into Crescendo.framework at archive time.
#
# Outputs (staged under build/artifacts/):
#   CTagLib.xcframework        static libCTagLib.a + ctaglib.h + module map;
#                              consumed only as a link input by the sibling
#                              Crescendo engine build. Never a runtime
#                              framework, never a release asset.
#   taglib-dist/               the license/provenance material the engine
#                              build and release flow embed and verify:
#     COPYING.MPL              TagLib's MPL 1.1 text (from the verified tree)
#     TagLib-NOTICE.txt        generated notice (version, MPL election,
#                              corresponding source, EULA exclusion)
#     taglib-<version>.tar.gz  the verified source tarball, kept as the MPL
#                              corresponding-source archive (attached to each
#                              CrescendoKit release by the release flow)
#     taglib-static.json       binds the artifact to its exact inputs (lock
#                              pin + shim/script/library hashes); the release
#                              flow refuses a stale artifact via this file
#
# TagLib is C++, so the thin `extern "C"` shim in Shims/TagLib/ctaglib.cpp is
# compiled alongside and merged with libtag.a into one static archive that
# Swift imports as the `CTagLib` module. EVERYTHING in the archive, including
# the ctaglib_* entry points, carries hidden visibility: the symbols resolve
# when the engine links the archive, then become non-exported locals of
# Crescendo.framework, so neither TagLib's C++ symbols nor the shim's C API
# leak into the engine's ABI or clash with a host app's own TagLib.
#
# TagLib is dual LGPL 2.1 / MPL 1.1; Crescendo elects MPL 1.1, whose
# file-level copyleft permits static linking into a proprietary Larger Work.
# The election obligates shipping the MPL text and corresponding source with
# the artifact, which taglib-dist/ supplies fail-closed. CMake (brew install
# cmake) is used to build TagLib; it is a build-time tool for this script
# only, never a `swift build` dependency.
#
# Supply-chain posture (fail-closed):
#   - The version comes from upstream.lock; the downloaded tarball must match
#     the recorded SHA-256 BEFORE extraction. TagLib publishes no release
#     signatures, so the hash pin is the integrity anchor (recorded once,
#     reviewed, then enforced on every build).
#   - The archive must contain both arches, the importable CTagLib module,
#     and no non-hidden ctaglib_*/TagLib symbols, or the build fails.
#   - The MPL license text must exist in the source tree and in the staged
#     taglib-dist/, or the build fails.
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${ROOT_DIR}/build/taglib"
ARTIFACTS_DIR="${ROOT_DIR}/build/artifacts"
SHIM_DIR="${ROOT_DIR}/Shims/TagLib"
LOCK_FILE="${ROOT_DIR}/upstream.lock"
LOG_FILE="${BUILD_DIR}/build.log"
FRAMEWORK_NAME="CTagLib"
DIST_DIR_NAME="taglib-dist"
MIN_MACOS="14.0"

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
# install trees or archives. Also clears the dirs the retired dynamic-framework
# pipeline used, so a checkout that predates the static switch cannot leak its
# old shape into a fresh build.
clean_stale_state() {
    rm -rf \
        "${BUILD_DIR}/install" \
        "${BUILD_DIR}/cmake-build" \
        "${BUILD_DIR}/static-build" \
        "${BUILD_DIR}/framework-build" \
        "${BUILD_DIR}/frameworks" \
        "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"
}

# Downloads and verifies the pinned source tarball, keeping the verified
# tarball at TARBALL: it is the MPL corresponding-source archive that
# stage_licenses ships, not a disposable intermediate.
download_taglib() {
    SRC_DIR="${BUILD_DIR}/taglib-${TAGLIB_VERSION}"
    TARBALL="${BUILD_DIR}/taglib-${TAGLIB_VERSION}.tar.gz"
    if [ -f "$TARBALL" ]; then
        log "TagLib ${TAGLIB_VERSION} tarball already present"
    else
        log "Downloading TagLib ${TAGLIB_VERSION}..."
        mkdir -p "$BUILD_DIR"
        # GitHub release asset: tag is v<version>, asset is
        # taglib-<version>.tar.gz. -L follows the 302 to the presigned URL.
        curl -fL "https://github.com/taglib/taglib/releases/download/v${TAGLIB_VERSION}/taglib-${TAGLIB_VERSION}.tar.gz" \
             -o "$TARBALL"
    fi

    verify_download "$TARBALL"

    # ALWAYS extract fresh from the verified bytes, never reuse a previously
    # extracted tree: a local edit or interrupted experiment in the ignored
    # source dir would otherwise be compiled while TagLib-NOTICE.txt claims
    # unmodified upstream source and the release ships the pristine tarball.
    rm -rf "$SRC_DIR"
    tar xf "$TARBALL" -C "$BUILD_DIR"
    [ -d "$SRC_DIR" ] || error "Extraction did not produce ${SRC_DIR}"
}

# Builds a static libtag.a (Release, universal arm64 + x86_64, hidden
# visibility, hardened) and installs it plus the public headers under
# build/taglib/install. CMake emits both arches in one pass via
# CMAKE_OSX_ARCHITECTURES, so libtag.a is already a fat archive.
build_taglib() {
    PREFIX="${BUILD_DIR}/install"
    local cmake_build="${BUILD_DIR}/cmake-build"
    rm -rf "$PREFIX" "$cmake_build"

    run_logged "Configuring TagLib ${TAGLIB_VERSION} (cmake, static, arm64 + x86_64, hardened)..." \
        "$CMAKE" -S "$SRC_DIR" -B "$cmake_build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_BINDINGS=OFF \
        -DBUILD_TESTING=OFF \
        -DWITH_ZLIB=ON \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_MACOS}" \
        -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
        -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
        -DCMAKE_CXX_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2 -DTRACE_IN_RELEASE" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX"

    run_logged "Compiling TagLib..." "$CMAKE" --build "$cmake_build" -j"$(sysctl -n hw.ncpu)"
    run_logged "Installing TagLib..." "$CMAKE" --install "$cmake_build"

    [ -f "${PREFIX}/lib/libtag.a" ] || error "TagLib build did not produce libtag.a"
}

# Compiles the C shim as a fat object. Two -arch flags make clang emit both
# slices, matching the universal libtag.a it will be merged with.
#
# -DTRACE_IN_RELEASE (both here and in the CMake flags) keeps TagLib's
# internal debug() diagnostics alive in the Release build so the log bridge
# (ctaglib_set_log_callback) has something to deliver; without it every call
# site compiles to a no-op under NDEBUG.
compile_shim() {
    WORK_DIR="${BUILD_DIR}/static-build"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    log "Compiling the CTagLib shim..."

    local sysroot
    sysroot="$(xcrun -sdk macosx --show-sdk-path)"

    xcrun -sdk macosx clang++ \
        -c "${SHIM_DIR}/ctaglib.cpp" \
        -o "${WORK_DIR}/ctaglib.o" \
        -std=c++17 \
        -arch arm64 \
        -arch x86_64 \
        -mmacosx-version-min="${MIN_MACOS}" \
        -isysroot "$sysroot" \
        -I"${SHIM_DIR}" \
        -I"${PREFIX}/include/taglib" \
        -DTAGLIB_STATIC \
        -DTRACE_IN_RELEASE \
        -O2 \
        "${HARDENING_FLAGS[@]}"
}

# Merges the shim object and libtag.a into the single static archive the
# engine links. FileRef references every format parser directly, so the
# engine's normal link pulls them all in (full format coverage). Nothing here
# is stripped or exported: every symbol is hidden-visibility, resolves when
# the engine links the archive, and the engine's own post-dSYM `strip -x`
# removes the local names from the shipped binary. libz stays a dynamic
# system library; the engine adds -lz (Package.swift linkerSettings) because
# a static archive cannot carry link flags.
create_static_library() {
    log "Merging shim + libtag.a into libCTagLib.a..."
    xcrun libtool -static \
        -o "${WORK_DIR}/libCTagLib.a" \
        "${WORK_DIR}/ctaglib.o" \
        "${PREFIX}/lib/libtag.a"
}

# Packages the archive as a library-form XCFramework: the canonical SwiftPM
# shape for a static binary target. SwiftPM/xcodebuild surface Headers/ (with
# the module map) at compile time, so `internal import CTagLib` resolves, and
# pass the .a as a link input per arch, so the engine archive folds the
# objects into Crescendo.framework for both slices. A plain (non-framework)
# module map because there is no framework bundle anymore.
create_xcframework() {
    local xcfw="${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"
    local hdrs="${WORK_DIR}/Headers"
    rm -rf "$xcfw" "$hdrs"
    mkdir -p "$hdrs"

    cp "${SHIM_DIR}/ctaglib.h" "$hdrs/ctaglib.h"
    cat > "$hdrs/module.modulemap" << MODULEMAP
module ${FRAMEWORK_NAME} {
    header "ctaglib.h"
    export *
}
MODULEMAP

    run_logged "Packaging static XCFramework..." xcodebuild -create-xcframework \
        -library "${WORK_DIR}/libCTagLib.a" \
        -headers "$hdrs" \
        -output "$xcfw"
}

# Fail-closed checks on the packaged archive: both arches present, the shim
# actually in it, nothing that would leak into Crescendo's exported ABI, and
# the CTagLib module importable exactly as the engine will import it.
verify_artifact() {
    local slice="${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework/macos-arm64_x86_64"
    local lib="${slice}/libCTagLib.a"
    [ -f "$lib" ] || error "Packaged XCFramework has no macos-arm64_x86_64/libCTagLib.a slice"

    log "Verifying the static archive..."

    local archs
    archs="$(lipo -archs "$lib")"
    echo "$archs" | grep -qw arm64  || error "libCTagLib.a is missing the arm64 slice (got: ${archs})"
    echo "$archs" | grep -qw x86_64 || error "libCTagLib.a is missing the x86_64 slice (got: ${archs})"

    # Symbol posture per arch: the shim must be present, and no ctaglib_* or
    # TagLib C++ symbol may be plain-external (only `private external`, the
    # archive-level form of hidden visibility, becomes a non-exported local
    # when the engine links the archive). grep runs without -q: under
    # pipefail an early -q exit SIGPIPEs nm mid-listing and fails the
    # pipeline even on a match.
    local arch leaks
    for arch in arm64 x86_64; do
        nm -arch "$arch" "$lib" 2>/dev/null | grep ' _ctaglib_read$' > /dev/null \
            || error "libCTagLib.a (${arch}) does not define ctaglib_read; the shim is missing"
        # Only DEFINED plain-external symbols can export; undefined externals
        # are the shim's references into libtag.a, resolved intra-archive at
        # the engine link, and are expected.
        leaks="$(nm -arch "$arch" -m "$lib" 2>/dev/null \
            | grep ' external ' | grep -v 'private external' \
            | grep -v '(undefined)' \
            | grep -E '_ctaglib_|N6TagLib' || true)"
        [ -z "$leaks" ] || error "libCTagLib.a (${arch}) has default-visibility symbols that would export from Crescendo:
${leaks}"
    done
    log "  Symbols: hidden (nothing would export from Crescendo)"

    # Import probe: type-check a Swift snippet against the packaged headers,
    # proving the module map + header the engine will consume actually work.
    printf 'internal import CTagLib\nlet probe: Void = { _ = ctaglib_read }()\n' \
        > "${WORK_DIR}/import-probe.swift"
    xcrun swiftc -typecheck "${WORK_DIR}/import-probe.swift" \
        -I "${slice}/Headers" >> "$LOG_FILE" 2>&1 \
        || error "The CTagLib module does not import from the packaged headers - see ${LOG_FILE}"
    log "  Module: imports cleanly"
}

# Stages the license and provenance material beside the artifact. SwiftPM
# never copies resources out of a static binary target, so this directory is
# the hand-off: the engine build embeds COPYING.MPL + TagLib-NOTICE.txt into
# Crescendo.framework's Resources fail-closed, and the release flow attaches
# the corresponding-source tarball and verifies taglib-static.json before
# folding the archive into a release.
stage_licenses() {
    local dist="${BUILD_DIR}/${DIST_DIR_NAME}"
    rm -rf "$dist"
    mkdir -p "$dist"

    log "Staging license + provenance material..."

    # MPL election: the license text ships inside Crescendo.framework.
    # Fail-closed: an artifact without its license text is a compliance
    # regression, not a warning.
    [ -f "${SRC_DIR}/COPYING.MPL" ] \
        || error "TagLib source tree has no COPYING.MPL; refusing to build an artifact without its license text"
    cp "${SRC_DIR}/COPYING.MPL" "$dist/COPYING.MPL"

    # The verified source tarball IS the corresponding source; keep it with
    # the artifact so the release flow can attach it without re-downloading.
    cp "$TARBALL" "$dist/taglib-${TAGLIB_VERSION}.tar.gz"

    # The notice embedded in Crescendo.framework. Dev builds carry this
    # generic form (the releases page); at release time the engine's
    # release.sh replaces the CrescendoKit releases URL line below with the
    # exact per-tag asset URL of the corresponding-source tarball before the
    # engine is built, so shipped frameworks name their release-specific
    # source location.
    cat > "$dist/TagLib-NOTICE.txt" << NOTICE
TagLib Notice for Crescendo.framework

Crescendo.framework statically incorporates the TagLib audio metadata
library, version ${TAGLIB_VERSION} (https://taglib.org).

TagLib is dual-licensed under the GNU Lesser General Public License
version 2.1 and the Mozilla Public License version 1.1 (MPL 1.1);
Crescendo elects the MPL 1.1. The full MPL 1.1 text ships beside this
notice as COPYING.MPL.

TagLib's source code is used unmodified. (Should a future build ever
modify TagLib-covered files, MPL 1.1 section 3.3 requires a dated
description of the modification and availability of the modified
source, and this notice must be updated to carry it.)

Exact corresponding source for the embedded TagLib:
  - Upstream release: https://github.com/taglib/taglib/releases/tag/v${TAGLIB_VERSION}
  - Source archive: taglib-${TAGLIB_VERSION}.tar.gz
      SHA-256: ${EXPECTED_SHA256}
    A verified copy of this archive is attached as an asset to the
    CrescendoKit release that distributes this framework:
    https://github.com/kushalpandya/CrescendoKit/releases
  - The CTagLib shim source and the build pipeline that reproduce the
    embedded component live in the public CrescendoKit repository
    (Shims/TagLib/ and Scripts/build-taglib.sh).

TagLib-covered code is excluded from the Crescendo End User License
Agreement: that agreement grants no rights over TagLib, imposes no
restrictions on it, and nothing in it limits any rights granted to you
by the MPL 1.1.
NOTICE

    # Bind the artifact to its exact inputs. The release flow verifies every
    # hash here against the lock, the current shim/script sources, and the
    # staged archive, so a stale static CTagLib can never fold into a release
    # silently (the static replacement for the retired zip-restage rule).
    local shim_h_sha shim_cpp_sha script_sha lib_sha
    shim_h_sha="$(shasum -a 256 "${SHIM_DIR}/ctaglib.h" | awk '{print $1}')"
    shim_cpp_sha="$(shasum -a 256 "${SHIM_DIR}/ctaglib.cpp" | awk '{print $1}')"
    script_sha="$(shasum -a 256 "${SCRIPT_DIR}/build-taglib.sh" | awk '{print $1}')"
    lib_sha="$(shasum -a 256 "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework/macos-arm64_x86_64/libCTagLib.a" | awk '{print $1}')"

    cat > "$dist/taglib-static.json" << JSON
{
  "taglib": {
    "version": "${TAGLIB_VERSION}",
    "sourceSha256": "${EXPECTED_SHA256}"
  },
  "inputs": {
    "ctaglib.h": "${shim_h_sha}",
    "ctaglib.cpp": "${shim_cpp_sha}",
    "build-taglib.sh": "${script_sha}"
  },
  "staticLibSha256": "${lib_sha}"
}
JSON

    # The file gates releases; prove it parses before anything trusts it.
    python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$dist/taglib-static.json" \
        || error "Generated taglib-static.json is not valid JSON"
}

publish() {
    mkdir -p "$ARTIFACTS_DIR"
    # Remove any prior artifact, including the retired dynamic-era outputs
    # (the framework-form xcframework plus its zip/checksum): a stale dynamic
    # CTagLib at this path would resurrect an @rpath load command in the
    # engine, which its build script now rejects fail-closed.
    rm -rf "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework" \
           "${ARTIFACTS_DIR}/${DIST_DIR_NAME}"
    rm -f  "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework.zip" \
           "${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework.checksum"

    log "Publishing to ${ARTIFACTS_DIR}..."
    cp -R "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework" "$ARTIFACTS_DIR/"
    cp -R "${BUILD_DIR}/${DIST_DIR_NAME}" "$ARTIFACTS_DIR/"

    # Post-build compliance gate: the license/notice material must have
    # survived into the published staging area; the engine build embeds it
    # from here fail-closed.
    local f
    for f in COPYING.MPL TagLib-NOTICE.txt "taglib-${TAGLIB_VERSION}.tar.gz" taglib-static.json; do
        [ -f "${ARTIFACTS_DIR}/${DIST_DIR_NAME}/${f}" ] \
            || error "Published ${DIST_DIR_NAME} is missing ${f}"
    done

    # No zip, checksum, or codesign: the archive is a link input consumed by
    # the sibling engine build, never a release asset or runtime framework.
    log "Prepared ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework (static) + ${DIST_DIR_NAME}/"
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
    # The engine's CTagLib target always reads this repo's staged artifact
    # (no env var; the static build input has no remote form). Use a local
    # CFFmpeg too when one is present so the verify does not trigger a
    # remote fetch mid-build.
    [ -d "${ARTIFACTS_DIR}/CFFmpeg.xcframework" ] && export CRESCENDO_LOCAL_FFMPEG=1
    if run_logged "Verifying with swift build (sibling Crescendo)..." swift build; then
        log "Prepared ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework"
    else
        error "swift build failed - see ${LOG_FILE}"
    fi
}

main() {
    command -v xcrun   >/dev/null || error "Xcode command line tools not found"
    command -v swift   >/dev/null || error "swift not found in PATH"
    command -v curl    >/dev/null || error "curl not found in PATH"
    command -v shasum  >/dev/null || error "shasum not found in PATH"
    command -v python3 >/dev/null || error "python3 not found in PATH"
    find_cmake

    log "TagLib static XCFramework builder - macOS universal (arm64 + x86_64), MPL 1.1"
    [ "$MODE" = "--check-updates" ] && check_updates
    [ -z "$MODE" ] || error "Unknown argument '$MODE'. The build takes no version argument; edit upstream.lock to change what gets built (--check-updates to compare pins)."
    resolve_version
    log "TagLib ${TAGLIB_VERSION} -> ${ARTIFACTS_DIR}/${FRAMEWORK_NAME}.xcframework (static)"

    mkdir -p "$BUILD_DIR"
    : > "$LOG_FILE"
    log "Complete Build Log: ${LOG_FILE}"

    clean_stale_state
    download_taglib
    build_taglib
    compile_shim
    create_static_library
    create_xcframework
    verify_artifact
    stage_licenses
    publish
    verify_swift_build

    log "Done."
}

main "$@"
