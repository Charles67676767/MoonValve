// Vendored from bikallem/compress 0.3.4, licensed under Apache-2.0.
// MoonValve modifications: attribution header and moon fmt syntax/format normalization; MoonBit 0.10.18 formatter normalization (type names and optional parameter syntax).
// Original source hashes and license: ../provenance.json and ../../../licenses/Apache-2.0.txt.

///|
/// Hasher is a trait for computing rolling checksums over byte data.
/// Aligned with moonbitlang/x CryptoHasher but returns UInt for 32-bit checksums.
pub(open) trait Hasher {
  /// Returns the hash output size in bytes.
  fn size(Self) -> Int32
  /// Resets the hasher to its initial state.
  fn reset(Self) -> Unit
  /// Feeds bytes into the running hash.
  fn update(Self, BytesView) -> Unit
  /// Returns the current checksum value.
  fn checksum(Self) -> UInt32
}
