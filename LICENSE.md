# License

CrescendoKit distributes artifacts under different licenses. This file is the
map; the authoritative texts live in [`LICENSES/`](LICENSES/) and inside the
binary artifacts themselves.

| What                                                         | License                                                                                                                                             |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| This repository's source (scripts, `Shims/`, manifest, docs) | [MIT](LICENSES/MIT.txt)                                                                                                                             |
| `Crescendo.xcframework`, `Crescendo.doccarchive`             | [Crescendo EULA](LICENSES/Crescendo-EULA.txt); embedded TagLib under MPL 1.1 (`Resources/COPYING.MPL` and `Resources/TagLib-NOTICE.txt` inside the framework) |
| `CFFmpeg.xcframework`                                        | LGPL 2.1+ (`Resources/COPYING.LGPLv2.1` inside the framework)                                                                                       |

## The Crescendo engine

`Crescendo.xcframework` is a mixed-license artifact. The engine itself is a
proprietary binary: the [Crescendo EULA](LICENSES/Crescendo-EULA.txt) defines
the narrow scope of permitted use, and a copy of it is embedded in the
framework's `Resources/`. Use beyond that scope requires written permission.
The framework also statically incorporates TagLib under the MPL 1.1;
TagLib-covered code is explicitly excluded from the EULA and remains governed
solely by the MPL (see below and `Resources/TagLib-NOTICE.txt`).

## Open source components

FFmpeg is built LGPL-only (no GPL, no non-free components) and consumed as a
dynamic framework, keeping it replaceable per LGPL section 6.

TagLib is dual LGPL 2.1 / MPL 1.1; this distribution elects the MPL 1.1 and
links it statically into `Crescendo.xcframework`. The MPL's file-level
copyleft covers the TagLib sources themselves, not the unrelated proprietary
Crescendo code in the same binary. TagLib's source is used unmodified, and the
exact verified source archive (`taglib-<version>.tar.gz`, SHA-256 recorded in
`provenance.json`) is attached to each release as the corresponding source.

The exact pinned source versions (`upstream.lock`), configure flags, build
scripts, and the `Shims/` sources needed to reproduce or replace either
component are published in this repository under the MIT license.

The machine-readable map at
[`LICENSES/license-map.json`](LICENSES/license-map.json) declares the shipped
binary artifacts, their licenses, embedded components, and the license
resources each framework must carry; the release flow fails if that map
drifts from what is actually shipped. Keep this file's prose consistent with
it.
