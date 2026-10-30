///|
fn cache_fixture(version : Int32, is_package : Bool) -> Bytes raise {
  let payload = @moonvalve.encode_binary(
    [
      {
        key: "appinfo",
        value: @moonvalve.ObjectValue([
          { key: "name", value: @moonvalve.StringValue("Synthetic Game"), },
        ]),
      },
    ],
    string_table=if version == 41 { Some(["appinfo", "name"]) } else { None },
  )
  let record = @buffer.Buffer()
  if !is_package {
    record.write_uint_le(1U)
    record.write_uint_le(1234567890U)
    record.write_uint64_le(9007199254740993UL)
  }
  record.write_bytes(Bytes::make(20, 0)[:])
  record.write_uint_le(7U)
  if !is_package && version >= 40 {
    record.write_bytes(Bytes::make(20, 1)[:])
  }
  if is_package && version >= 40 {
    record.write_uint64_le(9007199254740993UL)
  }
  record.write_bytes(payload[:])
  let bytes = record.to_bytes()
  let output = @buffer.Buffer()
  output.write_uint_le(
    (if is_package { 0x06565500U } else { 0x07564400U }) |
    version.reinterpret_as_uint(),
  )
  output.write_uint_le(1U)
  if version == 41 {
    output.write_uint64_le((16 + 8 + bytes.length() + 4).to_uint64())
  }
  output.write_uint_le(480U)
  if !is_package {
    output.write_uint_le(bytes.length().reinterpret_as_uint())
  }
  output.write_bytes(bytes[:])
  output.write_uint_le(if is_package { 0xffffffffU } else { 0U })
  if version == 41 {
    output.write_uint_le(2U)
    output.write_bytes(b"appinfo\x00name\x00"[:])
  }
  output.to_bytes()
}

///|
test "cache metadata pagination handles filtering boundaries and invalid page limits" {
  let cache = @moonvalve.open_steam_cache(cache_fixture(41, false))
  assert_eq(cache.page(query="48", limit=1).records[0].id, 480U)
  assert_eq(cache.page(query="48", offset=1).total, 1)
  assert_eq(cache.page(query="48", offset=1).records.length(), 0)
  assert_eq(cache.page(query="999").total, 0)
  for limit in [0, 201] {
    try cache.page(limit~) catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected invalid page size")
    }
  }
}

///|
test "Steam appinfo 39 40 41 and packageinfo 39 40 expose metadata and exact data" {
  for is_package in [false, true] {
    for version in [39, 40, 41] {
      if is_package && version == 41 {
        continue
      }
      let bytes = cache_fixture(version, is_package)
      let cache = @moonvalve.open_steam_cache(bytes)
      assert_eq(cache.version(), version)
      assert_eq(cache.universe(), 1U)
      assert_eq(cache.records().length(), 1)
      assert_eq(cache.records()[0].id, 480U)
      assert_eq(cache.records()[0].change_number, 7U)
      assert_eq(cache.read(999U), None)
      assert_eq(
        cache.read(480U),
        Some([
          {
            key: "appinfo",
            value: @moonvalve.ObjectValue([
              { key: "name", value: @moonvalve.StringValue("Synthetic Game"), },
            ]),
          },
        ]),
      )
    }
  }
}

///|
test "Steam caches reject truncated headers records tables sentinel and trailing data" {
  for is_package in [true, false] {
    let bytes = cache_fixture(if is_package { 40 } else { 41 }, is_package)
    for end in 0..<bytes.length() {
      try @moonvalve.open_steam_cache(bytes[:end].to_owned()) catch {
        @moonvalve.InvalidBinary(_, _) => ()
      } noraise {
        _ => fail("Expected incomplete cache")
      }
    }
    try @moonvalve.open_steam_cache(bytes + b"\x00") catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected trailing cache data")
    }
    try @moonvalve.open_steam_cache(bytes, max_records=0) catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected record limit")
    }
  }
}

///|
test "string-table binary and typed JSON preserve exact payloads" {
  let values : Array[@moonvalve.BinaryEntry] = [
    { key: "k", value: @moonvalve.UInt64Value(18446744073709551615UL), },
    { key: "k", value: @moonvalve.Float32Bits(0x7fc00001U), },
  ]
  let bytes = @moonvalve.encode_binary(values, string_table=Some(["k"]))
  assert_eq(@moonvalve.decode_binary(bytes, string_table=Some(["k"])), values)
  assert_eq(
    @moonvalve.binary_from_json(@moonvalve.binary_to_json(values)),
    values,
  )
  try @moonvalve.decode_binary(bytes, string_table=Some([])) catch {
    @moonvalve.InvalidBinary(_, _) => ()
  } noraise {
    _ => fail("Expected invalid key index")
  }
  try @moonvalve.encode_binary(values, string_table=Some(["other"])) catch {
    @moonvalve.InvalidBinary(_, _) => ()
  } noraise {
    _ => fail("Expected missing key")
  }
  try
    @moonvalve.binary_from_json(
      @json.parse(
        "[{\"key\":\"x\",\"type\":\"int32\",\"value\":\"2147483648\"}]",
      ),
    )
  catch {
    @moonvalve.InvalidBinary(_, _) => ()
    other => fail(other.to_string())
  } noraise {
    _ => fail("Expected numeric overflow")
  }
}
