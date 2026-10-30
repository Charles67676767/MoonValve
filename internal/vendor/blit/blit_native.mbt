// Vendored from bikallem/blit 0.2.2, licensed under Apache-2.0.
// MoonValve modifications: attribution header only; MoonBit 0.10.18 formatter normalization (type names and optional parameter syntax).
// Original source hashes and license: ../provenance.json and ../../../licenses/Apache-2.0.txt.

///|
/// Fast byte-level blit using libc memmove (vectorized).
/// FixedArray[Byte] has the same memory layout as Bytes in native backend.
#borrow(dst, src)
pub extern "c" fn blit_fixed_array(
  dst : FixedArray[Byte],
  dst_offset : Int32,
  src : FixedArray[Byte],
  src_offset : Int32,
  length : Int32,
) -> Unit = "bikallem_blit_blit_fixed_array"

///|
/// Copy `length` bytes from `src` (Bytes) at `src_offset` into `dst` (FixedArray) at `dst_offset`.
/// Uses memmove on native backend, safe for overlapping regions.
#borrow(dst, src)
pub extern "c" fn blit_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int32,
  src : Bytes,
  src_offset : Int32,
  length : Int32,
) -> Unit = "bikallem_blit_blit_fixed_array"

///|
/// Fill a byte array region with a single byte value (vectorized memset).
#borrow(dst)
pub extern "c" fn fill_bytes(
  dst : FixedArray[Byte],
  dst_offset : Int32,
  value : Byte,
  length : Int32,
) -> Unit = "bikallem_blit_fill_bytes"

///|
/// Word-at-a-time match length comparison using 8-byte chunks.
/// Returns the number of matching bytes between a[a_off..] and b[b_off..], up to max_len.
#borrow(a, b)
pub extern "c" fn match_length(
  a : FixedArray[Byte],
  a_offset : Int32,
  b : FixedArray[Byte],
  b_offset : Int32,
  max_len : Int32,
) -> Int32 = "bikallem_blit_match_length"

///|
/// Word-at-a-time match length comparison on Bytes (same layout as FixedArray[Byte] in native).
/// Returns the number of matching bytes between a[a_off..] and b[b_off..], up to max_len.
#borrow(a, b)
pub extern "c" fn match_length_bytes(
  a : Bytes,
  a_offset : Int32,
  b : Bytes,
  b_offset : Int32,
  max_len : Int32,
) -> Int32 = "bikallem_blit_match_length"

///|
/// Subtract `delta` from each of `len` elements, clamping to `floor`.
/// Used for hash-table window shifting in DEFLATE.
#borrow(arr)
pub extern "c" fn shift_int_array(
  arr : FixedArray[Int32],
  len : Int32,
  delta : Int32,
  floor : Int32,
) -> Unit = "bikallem_blit_shift_int_array"

///|
/// Allocate a FixedArray[Byte] without zeroing memory.
/// The caller MUST fully initialize the buffer before reading from it.
pub extern "c" fn make_uninit(len : Int32) -> FixedArray[Byte] = "bikallem_blit_make_uninit"

///|
/// Allocate a FixedArray[Int] without zeroing memory.
/// The caller MUST fully initialize all elements before reading.
pub extern "c" fn make_uninit_int(len : Int32) -> FixedArray[Int32] = "bikallem_blit_make_uninit_int"

///|
/// Allocate a FixedArray[UInt] without zeroing memory.
/// The caller MUST fully initialize all elements before reading.
pub extern "c" fn make_uninit_uint(len : Int32) -> FixedArray[UInt32] = "bikallem_blit_make_uninit_int"
