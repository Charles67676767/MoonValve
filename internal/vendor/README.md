# Compression sources

These Apache-2.0 sources come from the published Mooncakes packages
`bikallem/compress` 0.3.4 (Zstandard and XXH64) and `bikallem/blit` 0.2.2
(byte operations). XXH32 and its Hasher trait are also included to retain the original checksum tests.

Their original module manifests use `moon.mod.json`, which the Mooncakes
documentation builder no longer accepts. MoonValve uses local `moon.pkg`
imports instead. Source files carry explicit attribution and modification notices. The MoonBit formatter normalizes syntax and formatting (trailing commas and
explicit `fn` keywords); removed `try?` syntax is replaced with equivalent explicit
`Result` and `try`/`catch` expressions. Compression algorithms are unchanged. Deprecation diagnostics are
scoped to these vendor packages. Original and vendored normalized-LF
file hashes and paths are recorded in [provenance.json](provenance.json).
Generated `.mbti` interfaces are produced by MoonBit. These files are
third-party code and are excluded from MoonValve-authored source counts.

Upstream repositories:
- https://github.com/bikallem/compress
- https://github.com/bikallem/blit

Both package metadata and READMEs declare Apache-2.0; neither distributed
an additional NOTICE file. The license is included in
[Apache-2.0.txt](https://github.com/Charles67676767/MoonValve/blob/main/licenses/Apache-2.0.txt).
