///|
test "conditional precedence negation and explicit symbols" {
  assert_true(
    @moonvalve.evaluate_condition("($WIN32 || $OSX) && !$MOBILE", ["win32"]),
  )
  assert_true(!@moonvalve.evaluate_condition("$WIN32 && $MOBILE", ["WIN32"]))
  assert_true(@moonvalve.evaluate_condition("$X || $Y && $Z", ["$X"]))
  assert_true(!@moonvalve.evaluate_condition("$UNKNOWN", []))
}

///|
test "conditionals filter objects values and override after equals" {
  let options = {
    ..@moonvalve.ParseOptions::default(),
    conditions: Some(["WIN32"]),
  }
  let doc = @moonvalve.parse(
    "root { a one [$WIN32] a two [!$WIN32] b { k v } [$OSX] x = 10 x = [$WIN32] 20 c [$OSX] no [$WIN32] }",
    options~,
  )
  guard doc.get("root") is Some(@moonvalve.Object(entries)) else {
    fail("object")
  }
  assert_eq(entries.map(e => e.key), ["a", "x", "c"])
  assert_eq(doc.lookup(["root", "x"]), Some(@moonvalve.Text("20")))
}

///|
test "disabled branches are still validated and budgeted" {
  let options = {
    ..@moonvalve.ParseOptions::default(),
    conditions: Some([]),
    max_entries: 1,
  }
  ignore(expect_parse_error("root { k v } [$X]", "entry_limit", options~))
  ignore(expect_parse_error("k v [$X &&]", "invalid_condition", options~))
}

///|
test "conditional parser rejects malformed RHS even after true OR" {
  for expr in ["$X ||", "$X & $Y", "($X", "$", "$X trailing"] {
    try @moonvalve.evaluate_condition(expr, ["X"]) catch {
      @moonvalve.InvalidCondition(_) => ()
    } noraise {
      _ => fail("Expected invalid condition")
    }
  }
}
