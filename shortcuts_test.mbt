///|
test "shortcut CRUD preserves unknown fields exact identifiers and binary roundtrip" {
  let original : Array[@moonvalve.BinaryEntry] = [
    { key: "metadata", value: @moonvalve.StringValue("keep"), },
    {
      key: "shortcuts",
      value: @moonvalve.ObjectValue([
        {
          key: "0",
          value: @moonvalve.ObjectValue([
            { key: "AppName", value: @moonvalve.StringValue("Original"), },
            { key: "exe", value: @moonvalve.StringValue("game.exe"), },
            { key: "Custom", value: @moonvalve.StringValue("unchanged"), },
          ]),
        },
      ]),
    },
  ]
  let file = @moonvalve.read_shortcut_file(original)
  let first = file.shortcuts()[0]
  let changed = file.set({
    ..first,
    name: "Updated",
    launch_options: "--fullscreen",
    tags: ["Games", "中文"],
  })
  let added = changed.add(
    "Second",
    "\"D:\\Games\\two.exe\"",
    start_dir="D:\\Games",
  )
  let encoded = @moonvalve.encode_binary(added.to_binary())
  let decoded = @moonvalve.read_shortcut_file(@moonvalve.decode_binary(encoded))
  assert_eq(decoded.shortcuts().length(), 2)
  assert_eq(decoded.shortcuts()[0].app_id, first.app_id)
  assert_eq(decoded.shortcuts()[0].tags, ["Games", "中文"])
  assert_true(
    @moonvalve.binary_to_json(decoded.to_binary())
    .stringify()
    .contains("unchanged"),
  )
  assert_eq(decoded.remove("0").shortcuts()[0].name, "Second")
  assert_eq(file.shortcuts()[0].name, "Original")
}

///|
test "shortcut checksum matches independent CRC32 vector and rejects malformed models" {
  // CRC-32/ISO-HDLC("123456789") = 0xcbf43926.
  assert_eq(@moonvalve.shortcut_app_id("789", "123456"), 0xcbf43926U)
  let shortcut = @moonvalve.new_shortcut_file().add("789", "123456").shortcuts()[0]
  assert_eq(shortcut.url(), "steam://rungameid/14696434319421865984")
  try @moonvalve.read_shortcut_file([]) catch {
    @moonvalve.InvalidManifest(_) => ()
  } noraise {
    _ => fail("Expected missing root")
  }
  try @moonvalve.new_shortcut_file().add("", "x") catch {
    @moonvalve.InvalidManifest(_) => ()
  } noraise {
    _ => fail("Expected missing name")
  }
}
