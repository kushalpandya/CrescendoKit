// swift-tools-version: 6.0
import Foundation
import PackageDescription

// CrescendoKit: binary distribution of the Crescendo audio engine.
//
// Vends two prebuilt XCFrameworks as one product:
//   - Crescendo  (the engine; a mixed-license artifact: the proprietary
//                 Crescendo binary with the TagLib metadata library
//                 statically embedded under the MPL 1.1 - see LICENSE.md
//                 and the COPYING.MPL / TagLib-NOTICE.txt inside the
//                 framework's Resources)
//   - CFFmpeg    (FFmpeg, LGPL 2.1+, dynamically linked and replaceable)
//
// The product lists both targets because SwiftPM binary targets cannot
// declare dependencies on each other: Crescendo.framework links CFFmpeg via
// @rpath, and listing them together makes every consumer embed the pair
// automatically. Consumers `import Crescendo`.
//
// Two consumption modes per target:
//
//   1. Remote (default for consumers)
//      SwiftPM downloads each zip from this repo's release assets at the
//      stable per-tag URLs below and verifies its checksum. The URL and
//      checksum lines are rewritten by the release flow
//      (Crescendo's Scripts/release.sh); do not edit them by hand.
//
//   2. Local (for development)
//      Set CRESCENDOKIT_LOCAL=1 in the environment and SwiftPM consumes the
//      artifacts staged in build/artifacts (produced by Scripts/build-*.sh
//      and the engine's build, staged by the release flow) instead of
//      downloading. Until the first release populates the checksums, the
//      placeholder values make local mode the automatic fallback.

let crescendoURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.2.3/Crescendo.xcframework.zip"
let crescendoChecksum = "2bb7bb4ed40f5ab5bc8f1bf1da30a7298f2d969980420aab93e7de1ce3873e88"

let cffmpegURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.2.3/CFFmpeg.xcframework.zip"
let cffmpegChecksum = "607187a9e92d82817580c12a8d924f75b567707872e2da6d8fe248daa359d9f7"

let placeholderChecksum = "0000000000000000000000000000000000000000000000000000000000000000"

let useLocal = ProcessInfo.processInfo.environment["CRESCENDOKIT_LOCAL"] == "1"
    || crescendoChecksum == placeholderChecksum
    || cffmpegChecksum == placeholderChecksum

func binaryTarget(name: String, url: String, checksum: String) -> Target {
    useLocal
        ? .binaryTarget(name: name, path: "build/artifacts/\(name).xcframework")
        : .binaryTarget(name: name, url: url, checksum: checksum)
}

let package = Package(
    name: "CrescendoKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Crescendo", targets: ["Crescendo", "CFFmpeg"])
    ],
    targets: [
        binaryTarget(name: "Crescendo", url: crescendoURL, checksum: crescendoChecksum),
        binaryTarget(name: "CFFmpeg", url: cffmpegURL, checksum: cffmpegChecksum)
    ]
)
