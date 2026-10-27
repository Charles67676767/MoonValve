# References

MoonValve implements documented Valve KeyValues 1 text and standard binary behavior in MoonBit.

Compatibility references:

- Valve's KeyValues documentation: https://developer.valvesoftware.com/wiki/KeyValues
- ValvePython/vdf: https://github.com/ValvePython/vdf (MIT)
- ValveResourceFormat/ValveKeyValue: https://github.com/ValveResourceFormat/ValveKeyValue (MIT)

No upstream implementation source files or upstream test suites are distributed in this repository. Most fixtures are synthetic examples. The three original Proton production manifests/templates under fixtures/upstream/proton are reproduced from ValveSoftware/Proton at the commit recorded in provenance.json under BSD-3-Clause; the original LICENSE.proton is included in that directory. These configuration data files retain their upstream license; MoonValve implementation code remains MIT. The binary reference vectors are generated from synthetic values with ValvePython/vdf 3.4; the optional differential test imports that MIT-licensed package at test runtime. No Python dependency is required by the library or CLI. The MoonBit standard library is supplied by the MoonBit toolchain rather than vendored here.

Valve and Steam names identify the supported ecosystem. MoonValve is an independent project and is not affiliated with Valve.

Additional compatibility references: xPaw/SteamAppInfo (Steam cache headers), Corecii/steam-binary-vdf-ts (shortcut format and identifier behavior), and ValveKeyValue 0.70.0.499 (optional .NET test runtime). MoonValve does not vendor their implementation files. The CRC-32 checksum is implemented independently from the standard polynomial and checked against a known vector.

Binary distributions include the MoonBit native runtime and compiled standard-library code. The distribution script supplies Apache-2.0, the standard library's original NOTICE and native-runtime attribution in licenses/. Python and .NET reference dependencies are not included in product packages.
