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

let crescendoURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.0.1/Crescendo.xcframework.zip"
let crescendoChecksum = "13b554762e64f372fb72485b0d02199087639491508598e0a4f4d190b9957531"

let cffmpegURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.0.1/CFFmpeg.xcframework.zip"
let cffmpegChecksum = "c978431175efbdd124a79db21aa902b5ea1739eb4759d1dd98ab790608cbfc7a"

let ctaglibURL = "https://github.com/kushalpandya/CrescendoKit/releases/download/v1.0.1/CTagLib.xcframework.zip"
let ctaglibChecksum = "c2157b1144a5e7af0ebabdc874243c9c301c188f42e5e70734f0ab8ec2db8157"

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
