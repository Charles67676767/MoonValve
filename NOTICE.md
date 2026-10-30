# References

MoonValve implements documented Valve KeyValues 1 text and standard binary behavior in MoonBit.

Compatibility references:

- Valve's KeyValues documentation: https://developer.valvesoftware.com/wiki/KeyValues
- ValvePython/vdf: https://github.com/ValvePython/vdf (MIT)
- ValveResourceFormat/ValveKeyValue: https://github.com/ValveResourceFormat/ValveKeyValue (MIT)

Except for the Apache-2.0 compression sources described below, no upstream implementation source files or upstream test suites are distributed in this repository. Most fixtures are synthetic examples. The three original Proton production manifests/templates under fixtures/upstream/proton are reproduced from ValveSoftware/Proton at the commit recorded in provenance.json under BSD-3-Clause; the original LICENSE.proton is included in that directory. These configuration data files retain their upstream license; MoonValve implementation code remains MIT. The binary reference vectors are generated from synthetic values with ValvePython/vdf 3.4; the optional differential test imports that MIT-licensed package at test runtime. No Python dependency is required by the library or CLI. The MoonBit standard library is supplied by the MoonBit toolchain rather than vendored here.

Valve and Steam names identify the supported ecosystem. MoonValve is an independent project and is not affiliated with Valve.

Additional compatibility references: xPaw/SteamAppInfo (Steam cache headers), Corecii/steam-binary-vdf-ts (shortcut format and identifier behavior), and ValveKeyValue 0.70.0.499 (optional .NET test runtime). MoonValve does not vendor their implementation files. The CRC-32 checksum is implemented independently from the standard polynomial and checked against a known vector.

Binary distributions include the MoonBit native runtime and compiled standard-library code. The distribution script supplies compression provenance, Apache-2.0, the standard library's original NOTICE and native-runtime attribution in licenses/. Python and .NET reference dependencies are not included in product packages.

The Zstandard implementation is vendored from `bikallem/compress` 0.3.4
(Zstandard and XXH64, plus XXH32 needed by the original checksum tests) and
`bikallem/blit` 0.2.2 (byte operations), under Apache-2.0. Sources and original
tests are in `internal/vendor`; package imports/manifests are adapted. MoonBit
formatting normalizes syntax (commas and explicit fn keywords), without algorithm
changes. Deprecation warnings are scoped to the vendored packages.
`internal/vendor/provenance.json` records original file hashes, paths, versions
and repository URLs. Both published packages declare Apache-2.0 in metadata and
README; no additional upstream NOTICE is supplied. The full Apache-2.0 license
is included under `licenses/Apache-2.0.txt`. Vendored sources retain Apache-2.0
and are not part of MoonValve-authored MIT code. No external Mooncakes module
dependency or async runtime is required.

Additional format/compatibility references are ValveResourceFormat (MIT), pinned
format reference commit `2a45474046bdb5eb62c5685cbfad9e085fd2d293`, and srctools (MIT).
The optional independent test adapters use ValveResourceFormat 20.1.7467,
srctools 2.7.0 and polib 1.2.0 (MIT); they do not execute in the library, CLI or
workbench. VPK/LZ4/DMX/localization implementations are written in MoonBit against
the format layouts; upstream implementation files are not vendored. Original
game-resource fixtures used for optional local compatibility checks are not
redistributed by this project. All examples added for asset workflows are synthetic.
