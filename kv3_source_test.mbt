///|
test "KV3 local edits preserve comments, CRLF, flags and numeric spelling" {
  let text = "// lead\r\n{\r\n  name = 'Moon' // name\r\n  list = [1 /* ,keep */, 2, /* tail */]\r\n  asset = resource:{path='a'}\r\n  id = +18446744073709551615\r\n}\r\n// end"
  let source = @moonvalve.parse_kv3_preserving(text, allow_headerless=true)
  let edited = source.edit(
    ["name"],
    @moonvalve.KV3Replace(@moonvalve.KV3String("Sun")),
  )
  assert_eq(edited.text(), text.replace_all(old="'Moon'", new="\"Sun\""))
  let edited = edited.edit(
    ["asset", "path"],
    @moonvalve.KV3Replace(@moonvalve.KV3String("b")),
  )
  assert_true(edited.text().contains("resource:{path=\"b\"}"))
  let removed = edited.edit(["list", "0"], @moonvalve.KV3Remove)
  assert_true(removed.text().contains("[ /* ,keep */ 2, /* tail */]"))
  assert_true(removed.text().contains("id = +18446744073709551615\r\n"))
  assert_eq(source.text(), text)
  let renamed = source.edit(["name"], @moonvalve.KV3Rename("display name"))
  assert_eq(
    renamed.text(),
    text.replace_all(old="name =", new="\"display name\" ="),
  )
}

///|
test "KV3 every array insertion and deletion boundary with comments" {
  for
    raw in [
      "[1,2,3]", "[1,2,3,]", "[1/*,*/, // ,\n2, /*tail*/3 /*end*/]", "resource:[1,2,3]",
      "[1, // continued\\\n, still comment\n2,3]",
    ] {
    let source = @moonvalve.parse_kv3_preserving(raw, allow_headerless=true)
    for index in 0..<=3 {
      let inserted = source.edit(
        [],
        @moonvalve.KV3InsertElement(index, @moonvalve.KV3Integer("4")),
      )
      let restored = inserted.edit([index.to_string()], @moonvalve.KV3Remove)
      assert_eq(restored.document(), source.document())
      assert_true(restored.text().contains("/*,*/") == raw.contains("/*,*/"))
    }
    for index in 0..<3 {
      let removed = source.edit([index.to_string()], @moonvalve.KV3Remove)
      assert_eq(
        @moonvalve.parse_kv3(removed.text(), allow_headerless=true),
        removed.document(),
      )
    }
  }
  for raw in ["[]", "[/*keep*/]", "[1]", "[1,/*keep*/]"] {
    let source = @moonvalve.parse_kv3_preserving(raw, allow_headerless=true)
    let inserted = source.edit(
      [],
      @moonvalve.KV3InsertElement(0, @moonvalve.KV3Null),
    )
    assert_true(inserted.text().contains("null"))
    let removed = inserted.edit(["0"], @moonvalve.KV3Remove)
    assert_eq(removed.document(), source.document())
  }
}

///|
test "KV3 object insertion and transaction rollback" {
  let source = @moonvalve.parse_kv3_preserving(
    "{a=1 /*keep*/ b=[true]}",
    allow_headerless=true,
  )
  for index in 0..<=2 {
    let inserted = source.edit(
      [],
      @moonvalve.KV3InsertField(index, "c", @moonvalve.KV3Bool(false)),
    )
    assert_eq(
      inserted.edit(["c"], @moonvalve.KV3Remove).document(),
      source.document(),
    )
    assert_true(inserted.text().contains("/*keep*/"))
  }
  let plan = @json.parse(
    "[{\"op\":\"replace\",\"path\":[\"a\"],\"value\":{\"type\":\"integer\",\"value\":\"2\"}},{\"op\":\"remove\",\"path\":[\"missing\"]}]",
  )
  let failed = try {
    source.apply_json(plan) |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(source.text(), "{a=1 /*keep*/ b=[true]}")
  for
    plan in [
      "[{\"op\":\"rename\",\"path\":[\"a\"],\"key\":\"b\"}]", "[{\"op\":\"remove\",\"path\":[]}]",
      "[{\"op\":\"insert-element\",\"path\":[\"b\"],\"index\":1.5,\"value\":{\"type\":\"null\",\"value\":null}}]",
    ] {
    assert_true(
      try {
        source.apply_json(@json.parse(plan)) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      source.edit(["b", "00"], @moonvalve.KV3Remove) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.edit(["b", "0"], @moonvalve.KV3Rename("x")) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.edit([], @moonvalve.KV3Replace(@moonvalve.KV3Integer("oops")))
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}
