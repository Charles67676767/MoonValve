///|
fn generated_text(seed : Int32, depth : Int32) -> @moonvalve.Document {
  let entries : Array[@moonvalve.Entry] = []
  for i in 0..<(seed % 7 + 1) {
    let key = ["dup", "dup", "中文😀", "space key", "", "quote\"", "path\\"][i]
    let value = if depth > 0 && (seed + i) % 3 == 0 {
      @moonvalve.Object(generated_text(seed * 3 + i, depth - 1).entries)
    } else {
      @moonvalve.Text(
        ["", "a\nb\r\tc", "中文😀", "// literal {} []", "\\\"", "normal"][(
          seed + i
        ) %
        6],
      )
    }
    entries.push({ key, value, })
  }
  { entries, }
}

///|
test "generated documents roundtrip through text JSON and preserved source" {
  for seed in 0..<300 {
    let doc = generated_text(seed, 3)
    let text = @moonvalve.stringify(doc)
    assert_eq(@moonvalve.parse(text), doc)
    assert_eq(@moonvalve.parse_json_document(doc.to_json().stringify()), doc)
    assert_eq(@moonvalve.parse_preserving(text).text(), text)
    // Independent semantic oracle: replacing a selected root occurrence
    // must affect precisely that entry and leave all other entries identical.
    let index = seed % doc.entries.length()
    let key = doc.entries[index].key
    let mut occurrence = 0
    for i in 0..<index {
      if doc.entries[i].key == key {
        occurrence += 1
      }
    }
    let expected = doc.entries.map(e => e)
    expected[index] = { key, value: @moonvalve.Text("replacement"), }
    let edited = @moonvalve.parse_preserving(text).edit(
      [{ key, occurrence, }],
      @moonvalve.Replace(@moonvalve.Text("replacement")),
    )
    assert_eq(edited.document().entries, expected)
  }
}

///|
test "generated typed binary roundtrips and appended data always fails" {
  for seed in 0..<300 {
    let entries : Array[@moonvalve.BinaryEntry] = [
      { key: "i", value: @moonvalve.Int32Value(seed * -7919), },
      {
        key: "i",
        value: @moonvalve.UInt64Value(9007199254740993UL + seed.to_uint64()),
      },
      {
        key: "bits",
        value: @moonvalve.Float32Bits(seed.reinterpret_as_uint() * 0x9e3779b9U),
      },
      {
        key: "nested",
        value: @moonvalve.ObjectValue([
          { key: "text", value: @moonvalve.WideString("\uFEFF中文😀"), },
        ]),
      },
      { key: "utf8", value: @moonvalve.StringValue("\uFEFFdata"), },
    ]
    let bytes = @moonvalve.encode_binary(entries)
    assert_eq(@moonvalve.decode_binary(bytes), entries)
    try @moonvalve.decode_binary(bytes + b"\x00") catch {
      @moonvalve.InvalidBinary(_, _) => ()
    } noraise {
      _ => fail("Expected trailing bytes error")
    }
  }
}

///|
test "malformed conditional operators and deeply nested expressions are bounded" {
  for
    expression in [
      "$A | | $B",
      "$A & & $B",
      "$A ||",
      "($A",
      "!".repeat(70) + "$A",
    ] {
    try @moonvalve.evaluate_condition(expression, ["A"]) catch {
      @moonvalve.InvalidCondition(_) => ()
    } noraise {
      _ => fail("Expected malformed condition")
    }
  }
}

///|
test "mutated valid documents yield located errors rather than partial results" {
  for seed in 0..<200 {
    let text = @moonvalve.stringify(generated_text(seed, 2))
    for broken in ["}" + text, text + "\"unterminated", "root { " + text] {
      try @moonvalve.parse(broken) catch {
        @moonvalve.ParseError(d) => {
          assert_true(d.offset >= 0 && d.offset <= broken.char_length())
          assert_true(d.line >= 1 && d.column >= 1)
        }
      } noraise {
        _ => fail("Expected mutation error")
      }
    }
  }
}
