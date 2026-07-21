# CrescendoKit

<div align="center">
  <img src=".github/CrescendoLogo.png" alt="Crescendo Logo" width="300px"/>
</div>
<br/>

Binary distribution of **Crescendo**, a comprehensive Swift audio playback engine for Apple
platforms.

```swift
dependencies: [
    .package(url: "https://github.com/kushalpandya/CrescendoKit", from: "<latest available version>")
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

## Documentation

API documentation for the latest release is published at
[kushalpandya.github.io/CrescendoKit](https://kushalpandya.github.io/CrescendoKit/).

## Package Artifacts

Release packages include prebuilt XCFrameworks (macOS, universal for Apple Silicon and Intel; other platforms in future):

| Framework               | Description                                              | License                        |
| ----------------------- | -------------------------------------------------------- | ------------------------------ |
| `CFFmpeg.xcframework`   | FFmpeg, audio-only LGPL build, dynamically linked        | LGPL 2.1+                      |
| `Crescendo.xcframework` | The playback engine with TagLib statically embedded      | Proprietary (EULA) + MPL 1.1   |
| `Crescendo.doccarchive` | Public API documentation                                 | Proprietary (EULA)             |

`Crescendo.xcframework` is a mixed-license artifact: the proprietary engine
statically incorporates [TagLib](https://taglib.org/) (plus the thin C shim
whose source lives in `Shims/`) under the MPL 1.1. The framework's
`Resources/` carry `COPYING.MPL` and `TagLib-NOTICE.txt` alongside the
Crescendo EULA, and each release attaches the exact verified TagLib source
archive (`taglib-<version>.tar.gz`) as its corresponding source.

The product lists both frameworks because Crescendo links `CFFmpeg` via
`@rpath`; consumers embed the two XCFrameworks automatically.

## Building Dependencies

The [FFmpeg](https://ffmpeg.org/) and [TagLib](https://taglib.org/) artifacts can be built from source
using the scripts included in this project.

```bash
./Scripts/build-ffmpeg.sh    # requires nasm + gpg (brew install nasm gnupg)
./Scripts/build-taglib.sh    # requires cmake (brew install cmake)
```

`upstream.lock` controls the version and authenticity of the downloaded sources: it pins each
upstream release version together with its tarball's SHA-256 hash, verified before extraction.
FFmpeg downloads are additionally verified against the FFmpeg release signing key present in
`Keys/ffmpeg-signing-key.asc`.

Run either script with `--check-updates` to compare the pins against the latest upstream releases;
the lock file's comments describe the update workflow.

## License

See [LICENSE.md](LICENSE.md) for the full map. In short:

- **This repository's source** (build scripts, `Shims/`, manifest) is
  [MIT](LICENSES/MIT.txt).
- **FFmpeg** is built LGPL-only (no GPL, no non-free components; TLS via
  Apple SecureTransport) and consumed as a dynamic framework, keeping it
  replaceable per LGPL §6. The license text ships inside the framework
  (`Resources/COPYING.LGPLv2.1`), and the exact source version, configure
  flags, and build script live in this repository.
- **TagLib** is dual LGPL 2.1 / MPL 1.1; this distribution elects the
  **MPL 1.1** and embeds TagLib statically inside `Crescendo.xcframework`
  (the MPL's file-level copyleft permits this in a proprietary Larger Work).
  The license text and a notice identifying the exact version and
  corresponding source ship inside the framework (`Resources/COPYING.MPL`,
  `Resources/TagLib-NOTICE.txt`); TagLib's source is used unmodified, the
  verified source archive is attached to every release, and the shim source
  plus the build pipeline that reproduce the embedded component are published
  in `Shims/` and `Scripts/build-taglib.sh`.
- **Crescendo** is a proprietary binary, licensed under the
  [Crescendo EULA](LICENSES/Crescendo-EULA.txt). For uses beyond its scope,
  please get in touch.

## Author

[Kushal Pandya](https://doublslash.com/about/)
