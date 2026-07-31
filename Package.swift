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

let crescendoURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.2.2/Crescendo.xcframework.zip"
let crescendoChecksum = "447b9b36a6a1c7bd42b59a1a5a2335fad886aab15b0cc27371b44e073537a385"

let cffmpegURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.2.2/CFFmpeg.xcframework.zip"
let cffmpegChecksum = "ce6bb5db35e36c1e6bc1daa99ae2d0f83141d3dcfe658fcaa91b0f49cb4581af"

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
