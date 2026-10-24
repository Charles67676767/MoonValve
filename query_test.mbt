///|
test "query expressions retain duplicate paths wildcard recursion and stable preorder" {
  let doc = @moonvalve.parse(
    "root { tag one tag two nested { tag three x yes } } root { tag four }",
  )
  assert_eq(doc.select("/root/tag").map(v => v.value.as_text().unwrap()), [
    "one", "two", "four",
  ])
  assert_eq(doc.select("/root[0]/tag[1]")[0].value, @moonvalve.Text("two"))
  assert_eq(doc.select("/**/tag").map(v => v.value.as_text().unwrap()), [
    "one", "two", "three", "four",
  ])
  assert_eq(
    doc.select("/**/**/tag").map(v => v.value),
    doc.select("/**/tag").map(v => v.value),
  )
  assert_eq(doc.select("/root/*?kind=object").length(), 1)
  assert_eq(doc.select("$")[0].path, [])
}

///|
test "query key escapes and textual numeric filters are exact and typed" {
  let doc = @moonvalve.parse(
    "\"a/b\" { \"*\" yes \"x[0]?~\" ok } n -3 n 12 n text n NaN path materials/moon",
  )
  assert_eq(doc.select("/a~1b/~2")[0].value, @moonvalve.Text("yes"))
  assert_eq(doc.select("/a~1b/x~30~4~5~0")[0].value, @moonvalve.Text("ok"))
  for
    expression in [
      "/path?^=\"materials/\"", "/path?*=\"moon\"", "/path?$=\"moon\"", "/path?==\"materials/moon\"",
    ] {
    assert_eq(doc.select(expression).length(), 1)
  }
  assert_eq(doc.select("/n?>=0").map(v => v.value), [@moonvalve.Text("12")])
  assert_eq(doc.select("/n?<-2").map(v => v.value), [@moonvalve.Text("-3")])
  assert_eq(doc.select("/n?!=\"text\"").length(), 3)
  assert_eq(doc.select("/missing"), [])
}

///|
test "query rejects malformed expressions and exceeds budgets without partial success" {
  for
    expression in [
      "root", "/a~", "/a~9", "/x[-1]", "/x[9999999999999999999]", "/x?", "/x?==unquoted",
      "/x?kind=number", "/x?>NaN",
    ] {
    try @moonvalve.compile_query(expression) catch {
      @moonvalve.InvalidQuery(_) => ()
    } noraise {
      _ => fail("Expected invalid query: " + expression)
    }
  }
  let doc = @moonvalve.parse("k one k two")
  try @moonvalve.compile_query("/*").select(doc, max_matches=1) catch {
    @moonvalve.InvalidQuery(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected match budget")
  }
  try @moonvalve.compile_query("/*").select(doc, max_visited=1) catch {
    @moonvalve.InvalidQuery(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected visit budget")
  }
}

///|
test "snapshot deletion and rename never shift selected duplicate identities" {
  let source = @moonvalve.parse_preserving(
    "// preserve\r\nr { a one b two a three b four }\r\n",
  )
  let removed = source.edit_query("/r/a", @moonvalve.RemoveMatches)
  assert_eq(removed.document().select("/r/b").length(), 2)
  let renamed = source.edit_query("/r/*", @moonvalve.RenameKey("a"))
  assert_eq(
    renamed.document().select("/r/a").map(v => v.value.as_text().unwrap()),
    ["one", "two", "three", "four"],
  )
  assert_true(renamed.text().has_prefix("// preserve\r\n"))
  assert_eq(source.document().select("/r/a").length(), 2)
}

///|
test "snapshot edits reject overlapping selections and prefix transforms retain conditions" {
  let source = @moonvalve.parse_preserving(
    "r { path materials/a [$WIN32] path materials/b }",
  )
  let changed = source.edit_query(
    "/**/path?^=\"materials/\"",
    @moonvalve.ReplacePrefix("materials/", "assets/"),
  )
  assert_eq(changed.text(), "r { path assets/a [$WIN32] path assets/b }")
  try source.edit_query("/**", @moonvalve.RemoveMatches) catch {
    @moonvalve.InvalidEdit(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected overlapping selection")
  }
  try source.edit_query("/**", @moonvalve.SetText("bad")) catch {
    @moonvalve.InvalidQuery(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected scalar mismatch")
  }
}

///|
test "optimized sequential replacement preserves repeated target and dependency semantics" {
  let source = @moonvalve.parse_preserving("r {a one b two}")
  let changes : Array[@moonvalve.Change] = [
    {
      path: [{ key: "r", occurrence: 0, }, { key: "a", occurrence: 0, }],
      operation: @moonvalve.Replace(@moonvalve.Text("first")),
    },
    {
      path: [{ key: "r", occurrence: 0, }, { key: "a", occurrence: 0, }],
      operation: @moonvalve.Replace(@moonvalve.Text("last")),
    },
  ]
  assert_eq(source.apply(changes).document().read_text(changes[0].path), "last")
  assert_eq(source.document().apply(changes).read_text(changes[0].path), "last")
}

///|
test "large query batch changes thousands of distinct original positions" {
  let text = StringBuilder()
  text.write_string("r {\n")
  for i in 0..<5000 {
    text.write_string("k value\{i}\n")
  }
  text.write_string("}\n")
  let source = @moonvalve.parse_preserving(text.to_string())
  let edited = source.edit_query("/r/k", @moonvalve.SetText("changed"))
  assert_eq(edited.document().select("/r/k?==\"changed\"").length(), 5000)
}
