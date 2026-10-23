# References

MoonValve implements documented Valve KeyValues 1 text and standard binary behavior in MoonBit.

Compatibility references:

- Valve's KeyValues documentation: https://developer.valvesoftware.com/wiki/KeyValues
- ValvePython/vdf: https://github.com/ValvePython/vdf (MIT)
- ValveResourceFormat/ValveKeyValue: https://github.com/ValveResourceFormat/ValveKeyValue (MIT)

No upstream implementation source files or upstream test suites are distributed in this repository. The included fixtures are synthetic examples. The binary reference vectors are generated from synthetic values with ValvePython/vdf 3.4; the optional differential test imports that MIT-licensed package at test runtime. No Python dependency is required by the library or CLI. The MoonBit standard library is supplied by the MoonBit toolchain rather than vendored here.

Valve and Steam names identify the supported ecosystem. MoonValve is an independent project and is not affiliated with Valve.
