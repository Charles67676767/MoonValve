///|
test "JSON round trip preserves empty objects duplicates and Unicode" {
  let before = @moonvalve.parse(
    "root { tag one tag two empty {} name \"游戏🎮\" }",
  )
  let after = @moonvalve.parse_json_document(before.to_json().stringify())
  assert_eq(after, before)
  assert_eq(@moonvalve.parse(@moonvalve.stringify(after)), before)
}

///|
test "JSON import rejects lossy or malformed shapes" {
  for
    text in [
      "{}", "null", "[1]", "[{\"key\":1,\"value\":\"x\"}]", "[{\"key\":\"x\"}]",
      "[{\"key\":\"x\",\"value\":true}]", "[{\"key\":\"x\",\"value\":\"y\",\"extra\":0}]",
      "[",
    ] {
    try @moonvalve.parse_json_document(text) catch {
      @moonvalve.InvalidJsonDocument(_) => ()
    } noraise {
      _ => fail("Expected invalid JSON document")
    }
  }
}

///|
test "JSON import uses global count depth and token budgets" {
  let doc = @moonvalve.parse("a { b c } d e")
  for
    options in [
      { ..@moonvalve.ParseOptions::default(), max_entries: 2, },
      { ..@moonvalve.ParseOptions::default(), max_depth: 0, },
      { ..@moonvalve.ParseOptions::default(), max_token_chars: 0, },
      { ..@moonvalve.ParseOptions::default(), max_input_chars: 1, },
    ] {
    try
      @moonvalve.parse_json_document(doc.to_json().stringify(), options~)
    catch {
      @moonvalve.InvalidJsonDocument(_) => ()
    } noraise {
      _ => fail("Expected resource limit")
    }
  }
}
