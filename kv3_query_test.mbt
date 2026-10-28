///|
test "KV3 queries traverse arrays and flags with strict types and conjunctive filters" {
  let doc = @moonvalve.parse_kv3(
    "{ assets=[resource:\"old/a&b\",\"old/plain\",resource:\"other\"] nested=resource:{name=\"Moon\"} \"a/b?\"=true }",
    allow_headerless=true,
  )
  let rows = doc.select(
    "/assets/*?type=string&flag=resource&^=\"old/\"&*=\"a&b\"",
  )
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].path, ["assets", "0"])
  assert_eq(doc.select("/**/name")[0].path, ["nested", "name"])
  assert_eq(doc.select("/a~1b~5?==true").length(), 1)
  assert_eq(doc.select("/assets/1?flag=none").length(), 1)
  assert_eq(doc.select("$?type=object").length(), 1)
  assert_eq(doc.select("/**/**/name").length(), 1)
  for
    expression in [
      "/assets[0]", "/**?type=unknown", "/**?flag=unknown", "/**?", "/**?^=true",
      "/**?=={}", "/**?type=string&&flag=none",
    ] {
    assert_true(
      try {
        doc.select(expression) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "KV3 integer predicates compare full uint64 values without double rounding" {
  let doc = @moonvalve.parse_kv3(
    "[9007199254740992,9007199254740993,18446744073709551615,-9223372036854775808,+0001,-0,1.0]",
    allow_headerless=true,
  )
  assert_eq(doc.select("/*?>9007199254740992").length(), 2)
  assert_eq(doc.select("/*?==18446744073709551615")[0].path, ["2"])
  assert_eq(doc.select("/*?<0").length(), 1)
  assert_eq(doc.select("/*?==1")[0].path, ["4"])
  assert_eq(doc.select("/*?==0")[0].path, ["5"])
  assert_eq(doc.select("/*?>=1.0").length(), 1)
  assert_eq(doc.select("/*?==1.00")[0].path, ["6"])
}

///|
test "KV3 query edits retain flags comments CRLF and exact numeric values" {
  let text = "//keep\r\n{ a=resource:\"old/a\" b=resource:\"old/b\" note=\"old/a\" n=18446744073709551615 }"
  let source = @moonvalve.parse_kv3_preserving(text, allow_headerless=true)
  let edited = source.edit_query(
    "/**?flag=resource",
    @moonvalve.KV3ReplacePrefix("old/", "new/"),
  )
  assert_eq(
    edited.text(),
    text.replace_all(old="resource:\"old/", new="resource:\"new/"),
  )
  assert_eq(edited.document().select("/**?flag=resource").length(), 2)
  let edited = edited.edit_query(
    "/n",
    @moonvalve.KV3SetValue(@moonvalve.KV3Integer("9007199254740993")),
  )
  assert_true(edited.text().contains("n=9007199254740993"))
  assert_eq(source.text(), text)
}

///|
test "KV3 snapshot deletion covers every adjacent and separated array subset" {
  for mask in 0..<64 {
    for trailing in [false, true] {
      let tokens : Array[String] = []
      let expected : Array[@moonvalve.KV3Value] = []
      for i in 0..<6 {
        let remove = (mask & (1 << i)) != 0
        tokens.push(if remove { "0" } else { "1" })
        if !remove {
          expected.push(@moonvalve.KV3Integer("1"))
        }
      }
      let text = "[" +
        tokens.join(", /*keep , */ ") +
        (if trailing { ",/*tail*/" } else { "/*tail*/" }) +
        "]"
      let result = @moonvalve.parse_kv3_preserving(text, allow_headerless=true).edit_query(
        "/*?==0",
        @moonvalve.KV3RemoveMatches,
      )
      assert_eq(result.document().root, @moonvalve.KV3Array(expected))
      assert_eq(result.text().split("/*keep , */").count(), 6)
      assert_true(result.text().contains("/*tail*/"))
    }
  }
}

///|
test "KV3 snapshot edits reject overlaps collisions and incompatible values atomically" {
  let source = @moonvalve.parse_kv3_preserving(
    "{a={x=1} b={x=2} arr=[1,2]}",
    allow_headerless=true,
  )
  for
    (expression, operation) in [
      ("/**", @moonvalve.KV3RemoveMatches),
      ("/*", @moonvalve.KV3RenameMatches("same")),
      ("/arr/*", @moonvalve.KV3RenameMatches("key")),
      ("$", @moonvalve.KV3RemoveMatches),
      ("/**/x", @moonvalve.KV3ReplacePrefix("old", "new")),
    ] {
    assert_true(
      try {
        source.edit_query(expression, operation) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(
    source.edit_query("/missing", @moonvalve.KV3RemoveMatches).text(),
    source.text(),
  )
  let replacement = source.edit_query(
    "$",
    @moonvalve.KV3SetValue(@moonvalve.KV3Bool(true)),
  )
  assert_eq(replacement.document().root, @moonvalve.KV3Bool(true))
  assert_eq(source.text(), "{a={x=1} b={x=2} arr=[1,2]}")
}

///|
test "KV3 node ranges use Unicode scalar offsets and include field keys" {
  let text = "//😀\r\n{\"中文\"=resource:{arr=[true]}}"
  let source = @moonvalve.parse_kv3_preserving(text, allow_headerless=true)
  let field = source.range(["中文"])
  assert_eq(field.selection_start, 6)
  assert_eq(field.selection_end, 10)
  let range = source.range(["中文", "arr", "0"])
  assert_eq(
    String::from_array(
      text.to_array()[range.selection_start:range.selection_end].to_owned(),
    ),
    "true",
  )
}
