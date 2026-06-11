// swift-tools-version: 6.0
import PackageDescription

// CrescendoKit: binary distribution of the Crescendo audio engine.
//
// Vends three prebuilt XCFrameworks as one product:
//   - Crescendo  (the engine; proprietary binary)
//   - CFFmpeg    (FFmpeg, LGPL 2.1+, dynamically linked and replaceable)
//   - CTagLib    (TagLib, MPL 1.1 elected)
//
// The product lists all three targets because SwiftPM binary targets cannot
// declare dependencies on each other: Crescendo.framework links the other two
// via @rpath, and listing them together makes every consumer embed the full
// trio automatically. Consumers `import Crescendo`.
//
// PROTOTYPE STATE: binary targets point at local paths. The release flow
// replaces them with public release-asset URLs plus checksums.

let package = Package(
    name: "CrescendoKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Crescendo", targets: ["Crescendo", "CFFmpeg", "CTagLib"])
    ],
    targets: [
        .binaryTarget(name: "Crescendo", path: "build/artifacts/Crescendo.xcframework"),
        .binaryTarget(name: "CFFmpeg", path: "build/artifacts/CFFmpeg.xcframework"),
        .binaryTarget(name: "CTagLib", path: "build/artifacts/CTagLib.xcframework")
    ]
)
