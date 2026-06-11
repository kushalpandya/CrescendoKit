# CrescendoKit

<div align="center">
  <img src=".github/CrescendoLogo.png" alt="Crescendo Logo" width="300px"/>
</div>
<br/>

Binary distribution of **Crescendo**, a comprehensive Swift audio playback engine for Apple
platforms.

```swift
dependencies: [
    .package(url: "https://github.com/kushalpandya/CrescendoKit", from: "1.0.0")
]
```

The product and module are named `Crescendo` (the package is the
distribution; the engine is what you use):

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "Crescendo", package: "CrescendoKit")
])
```

```swift
import Crescendo
```

## Package Artifacts

Release packages include prebuilt XCFrameworks (macOS Apple Silicon for now, other platforms in future):

| Framework               | Description                                       | License           |
| ----------------------- | ------------------------------------------------- | ----------------- |
| `CFFmpeg.xcframework`   | FFmpeg, audio-only LGPL build, dynamically linked | LGPL 2.1+         |
| `CTagLib.xcframework`   | TagLib + a thin C shim (source in `Shims/`)       | MPL 1.1 (elected) |
| `Crescendo.xcframework` | The playback engine (binary-only)                 | Proprietary       |
| `Crescendo.doccarchive` | Public API documentation                          | Proprietary       |

The product lists all four because Crescendo links `CFFmpeg` and `CTagLib` via
`@rpath`; consumers embed all three XCFrameworks automatically.

## Building Dependencies

The [FFmpeg](https://ffmpeg.org/) and [TagLib](https://taglib.org/) artifacts can be built from source
using the scripts included in this project.

```bash
./Scripts/build-ffmpeg.sh    # requires gpg (brew install gnupg)
./Scripts/build-taglib.sh    # requires cmake (brew install cmake)
```

`upstream.lock` controls the version and authenticity of the downloaded sources: it pins each
upstream release version together with its tarball's SHA-256 hash, verified before extraction.
FFmpeg downloads are additionally verified against the FFmpeg release signing key present in
`Keys/ffmpeg-signing-key.asc`.

Run either script with `--check-updates` to compare the pins against the latest upstream releases;
the lock file's comments describe the update workflow.

## Licensing

- **FFmpeg** is built LGPL-only (no GPL, no non-free components; TLS via
  Apple SecureTransport) and consumed as a dynamic framework, keeping it
  replaceable per LGPL §6. The license text ships inside the framework
  (`Resources/COPYING.LGPLv2.1`), and the exact source version, configure
  flags, and build script live in this repository.
- **TagLib** is dual LGPL 2.1 / MPL 1.1; this distribution elects the
  **MPL 1.1**. The license text ships inside the framework
  (`Resources/COPYING.MPL`); TagLib's source is used unmodified, and the shim
  source is published in `Shims/`.
- **Crescendo** is a proprietary binary. If you want to use it, please get in
  touch.

## Author

[Kushal Pandya](https://doublslash.com/about/)
