///|
test "bounded codecs handle frames chains malformed distances and output budgets" {
  for text in ["", "hello", "abcdef".repeat(1000), "中文😀"] {
    let bytes = @utf8.encode(text[:])
    for codec in [0, 1, 2] {
      let encoded = valve_compress(bytes, codec)
      assert_eq(
        valve_decompress(encoded, codec, bytes.length(), 1000000),
        bytes,
      )
      assert_true(
        try {
          valve_decompress(encoded, codec, bytes.length() + 1, 1000000)
          |> ignore
          false
        } catch {
          _ => true
        },
      )
    }
  }
  assert_eq(valve_lz4_decode(b"\x00\x01\x00", 4, b"a", 100), b"aaaa")
  assert_true(
    try {
      valve_lz4_decode(b"\x00\x00\x00", 4, b"", 100) |> ignore
      false
    } catch {
      _ => true
    },
  )
  let encoded = valve_compress(b"abc", 2)
  assert_true(
    try {
      valve_decompress(encoded, 2, 2, 100) |> ignore
      false
    } catch {
      _ => true
    },
  )
  let joined = @buffer.Buffer()
  joined.write_bytes(encoded[:])
  joined.write_bytes(encoded[:])
  assert_eq(valve_decompress(joined.to_bytes(), 2, 6, 1000000), b"abcabc")
}
