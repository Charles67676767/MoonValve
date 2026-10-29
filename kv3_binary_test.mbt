///|
test "binary KV3 4 and 5 preserve every numeric storage type and IEEE payload across codecs" {
  let root = @moonvalve.BObject([
    ("small", @moonvalve.BNumber(22, 255UL)),
    ("u8", @moonvalve.BNumber(23, 255UL)),
    ("i16", @moonvalve.BNumber(20, 65535UL)),
    ("u16", @moonvalve.BNumber(21, 65535UL)),
    ("i32", @moonvalve.BNumber(11, 4294967295UL)),
    ("u32", @moonvalve.BNumber(12, 4294967295UL)),
    ("signed", @moonvalve.BNumber(3, 9223372036854775808UL)),
    ("unsigned", @moonvalve.BNumber(4, 18446744073709551615UL)),
    ("nan32", @moonvalve.BNumber(19, 2143289345UL)),
    ("nan64", @moonvalve.BNumber(5, 9221120237041090561UL)),
    ("negative_zero", @moonvalve.BNumber(5, 9223372036854775808UL)),
    ("text", @moonvalve.BString("中文😀")),
    ("empty", @moonvalve.BString("")),
    (
      "resource",
      @moonvalve.BFlag("resource", @moonvalve.BString("materials/moon.vmat")),
    ),
    (
      "array",
      @moonvalve.BArray([
        @moonvalve.BNull,
        @moonvalve.BBool(true),
        @moonvalve.BBool(false),
        @moonvalve.BObject([]),
      ]),
    ),
    ("blob", @moonvalve.BBlob(b"\x00\x01\xff")),
    ("emptyblob", @moonvalve.BBlob(b"")),
  ])
  let doc : @moonvalve.KV3BinaryDocument = {
    version: 5,
    compression: 0,
    format_id: @moonvalve.generic_kv3_header().format_id,
    root,
  }
  for version in [4, 5] {
    for compression in [0, 1, 2] {
      let bytes = @moonvalve.encode_kv3_binary(doc, version~, compression~)
      let decoded = @moonvalve.decode_kv3_binary(bytes)
      assert_eq(decoded.root, root)
      assert_eq(decoded.version, version)
      assert_eq(decoded.compression, compression)
      assert_eq(decoded.format_id, doc.format_id)
      assert_true(
        @moonvalve.stringify_kv3(decoded.document()).contains(
          "18446744073709551615",
        ),
      )
      let roundtrip = @moonvalve.encode_kv3_binary(
        decoded,
        version~,
        compression~,
      )
      assert_eq(roundtrip, bytes)
    }
  }
}

///|
test "binary KV3 blob frames cross boundaries and truncation never returns partial trees" {
  let data = Bytes::from_array(Array::makei(70000, i => (i % 251).to_byte()))
  let document = @moonvalve.kv3_binary_from_document({
    header: Some(@moonvalve.generic_kv3_header()),
    root: @moonvalve.KV3Array([
      @moonvalve.KV3Blob(data),
      @moonvalve.KV3Blob(data),
      @moonvalve.KV3String("last"),
    ]),
  })
  for version in [4, 5] {
    for compression in [0, 1, 2] {
      let bytes = @moonvalve.encode_kv3_binary(document, version~, compression~)
      assert_eq(@moonvalve.decode_kv3_binary(bytes).root, document.root)
      for cut in [0, 1, 3, 4, 20, bytes.length() / 2, bytes.length() - 1] {
        assert_true(
          try {
            @moonvalve.decode_kv3_binary(bytes[:cut].to_owned()) |> ignore
            false
          } catch {
            _ => true
          },
        )
      }
      assert_true(
        try {
          @moonvalve.decode_kv3_binary(bytes, options={
            ..@moonvalve.BinaryOptions::default(),
            max_bytes: 100,
          })
          |> ignore
          false
        } catch {
          _ => true
        },
      )
    }
  }
}

///|
test "binary KV3 rejects unsupported versions invalid numeric widths duplicates and NUL strings" {
  let document = @moonvalve.kv3_binary_from_document(
    @moonvalve.parse_kv3("{a=1}", allow_headerless=true),
  )
  assert_true(
    try {
      @moonvalve.encode_kv3_binary(document, version=3) |> ignore
      false
    } catch {
      _ => true
    },
  )
  for
    root in [
      @moonvalve.BNumber(22, 256UL),
      @moonvalve.BNumber(99, 0UL),
      @moonvalve.BString("x\u0000y"),
      @moonvalve.BObject([("a", @moonvalve.BNull), ("a", @moonvalve.BNull)]),
    ] {
    assert_true(
      try {
        @moonvalve.encode_kv3_binary({ ..document, root, }) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}
