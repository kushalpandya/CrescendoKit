// swift-tools-version: 6.0
import Foundation
import PackageDescription

// CrescendoKit: binary distribution of the Crescendo audio engine.
//
// Vends three prebuilt XCFrameworks as one product:
//   - Crescendo  (the engine; proprietary binary, see LICENSE.md)
//   - CFFmpeg    (FFmpeg, LGPL 2.1+, dynamically linked and replaceable)
//   - CTagLib    (TagLib, MPL 1.1 elected)
//
// The product lists all three targets because SwiftPM binary targets cannot
// declare dependencies on each other: Crescendo.framework links the other two
// via @rpath, and listing them together makes every consumer embed the full
// trio automatically. Consumers `import Crescendo`.
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

let crescendoURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.1.1/Crescendo.xcframework.zip"
let crescendoChecksum = "6dab94eb177b19888d27dfb1b87d6b6372dc2df4589ce3b47977b20c4fc37526"

let cffmpegURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.1.1/CFFmpeg.xcframework.zip"
let cffmpegChecksum = "c978431175efbdd124a79db21aa902b5ea1739eb4759d1dd98ab790608cbfc7a"

let ctaglibURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.1.1/CTagLib.xcframework.zip"
let ctaglibChecksum = "9ea68d071bc1a86f75164bf58fc5f10ee3c0d8b2c3cd2b5f60d36dfee4916471"

let placeholderChecksum = "0000000000000000000000000000000000000000000000000000000000000000"

let useLocal = ProcessInfo.processInfo.environment["CRESCENDOKIT_LOCAL"] == "1"
    || crescendoChecksum == placeholderChecksum
    || cffmpegChecksum == placeholderChecksum
    || ctaglibChecksum == placeholderChecksum

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
        .library(name: "Crescendo", targets: ["Crescendo", "CFFmpeg", "CTagLib"])
    ],
    targets: [
        binaryTarget(name: "Crescendo", url: crescendoURL, checksum: crescendoChecksum),
        binaryTarget(name: "CFFmpeg", url: cffmpegURL, checksum: cffmpegChecksum),
        binaryTarget(name: "CTagLib", url: ctaglibURL, checksum: ctaglibChecksum)
    ]
)
