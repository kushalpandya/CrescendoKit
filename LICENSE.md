# License

CrescendoKit distributes artifacts under different licenses. This file is the
map; the authoritative texts live in [`LICENSES/`](LICENSES/) and inside the
binary artifacts themselves.

| What                                                         | License                                                                                    |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| This repository's source (scripts, `Shims/`, manifest, docs) | [MIT](LICENSES/MIT.txt)                                                                    |
| `Crescendo.xcframework`, `Crescendo.doccarchive`             | [Crescendo EULA](LICENSES/Crescendo-EULA.txt)                                              |
| `CFFmpeg.xcframework`                                        | LGPL 2.1+ (`Resources/COPYING.LGPLv2.1` inside the framework)                              |
| `CTagLib.xcframework`                                        | MPL 1.1, elected from TagLib's dual license (`Resources/COPYING.MPL` inside the framework) |

## The Crescendo engine

`Crescendo.xcframework` is a proprietary binary. The
[Crescendo EULA](LICENSES/Crescendo-EULA.txt) defines the narrow scope of
permitted use; a copy of it is embedded in the framework's `Resources/`. Use
beyond that scope requires written permission.

## Open source components

FFmpeg is built LGPL-only (no GPL, no non-free components) and consumed as a
dynamic framework, keeping it replaceable per LGPL section 6. The exact pinned
source version (`upstream.lock`), configure flags, build scripts, and the
`Shims/` sources needed to reproduce or replace either framework are published
in this repository under the MIT license. TagLib's source is used unmodified.
