///|
test "binary all types preserve duplicates Unicode and exact numeric bits" {
  let entries : Array[@moonvalve.BinaryEntry] = [
    { key: "dup", value: @moonvalve.StringValue("中文😀"), },
    { key: "dup", value: @moonvalve.Int32Value(-2147483648), },
    { key: "float", value: @moonvalve.Float32Bits(0x7fc00123U), },
    { key: "minuszero", value: @moonvalve.Float32Bits(0x80000000U), },
    { key: "ptr", value: @moonvalve.Pointer32(0xffffffffU), },
    { key: "wide", value: @moonvalve.WideString("中文😀"), },
    { key: "rgba", value: @moonvalve.Color32(0x04030201U), },
    { key: "unsigned", value: @moonvalve.UInt64Value(18446744073709551615UL), },
    { key: "signed", value: @moonvalve.Int64Value(-9223372036854775808L), },
    {
      key: "nested",
      value: @moonvalve.ObjectValue([
        { key: "empty", value: @moonvalve.ObjectValue([]), },
      ]),
    },
  ]
  assert_eq(
    @moonvalve.decode_binary(@moonvalve.encode_binary(entries)),
    entries,
  )
}

///|
test "binary known little endian fixture and empty terminator" {
  let bytes = b"\x02n\x00\xfe\xff\xff\xff\x08"
  assert_eq(@moonvalve.decode_binary(bytes), [
    { key: "n", value: @moonvalve.Int32Value(-2), },
  ])
  assert_eq(@moonvalve.encode_binary(@moonvalve.decode_binary(bytes)), bytes)
  assert_eq(@moonvalve.decode_binary(b"\x08"), [])
}

///|
test "binary rejects every truncated prefix unknown type trailing data and invalid encodings" {
  let bytes = @moonvalve.encode_binary([
    { key: "k", value: @moonvalve.WideString("😀"), },
  ])
  for end in 0..<bytes.length() {
    try @moonvalve.decode_binary(bytes[:end].to_owned()) catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected truncation error")
    }
  }
  for
    invalid in [
      b"\x09", b"\x08x", b"\x01k\x00\xff\x00\x08", b"\x05k\x00\x00\xd8\x00\x00\x08",
    ] {
    try @moonvalve.decode_binary(invalid) catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected format error")
    }
  }
}

///|
test "binary resource limits apply to encoding and decoding" {
  let entries : Array[@moonvalve.BinaryEntry] = [
    {
      key: "a",
      value: @moonvalve.ObjectValue([
        { key: "b", value: @moonvalve.StringValue("xyz"), },
      ]),
    },
  ]
  let bytes = @moonvalve.encode_binary(entries)
  for
    options in [
      { ..@moonvalve.BinaryOptions::default(), max_depth: 0, },
      { ..@moonvalve.BinaryOptions::default(), max_entries: 1, },
      { ..@moonvalve.BinaryOptions::default(), max_bytes: 2, },
      { ..@moonvalve.BinaryOptions::default(), max_string_bytes: 2, },
    ] {
    try @moonvalve.encode_binary(entries, options~) catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected encode limit")
    }
    try @moonvalve.decode_binary(bytes, options~) catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected decode limit")
    }
  }
}
