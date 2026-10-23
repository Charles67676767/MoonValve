///|
test "nested entries preserve duplicates and order" {
  let doc = @moonvalve.parse("root { tag one tag two nested { value yes } }")
  assert_eq(
    doc.lookup(["root", "nested", "value"]),
    Some(@moonvalve.Text("yes")),
  )
  guard doc.get("root") is Some(@moonvalve.Object(entries)) else {
    fail("Expected object")
  }
  assert_eq(entries.length(), 3)
  assert_eq(entries[0].value, @moonvalve.Text("one"))
  assert_eq(entries[1].value, @moonvalve.Text("two"))
}

///|
test "empty document and empty object are distinct" {
  assert_eq(@moonvalve.parse("").entries.length(), 0)
  assert_eq(
    @moonvalve.parse("root {}").get("root"),
    Some(@moonvalve.Object([])),
  )
}

///|
test "comments are trivia and slashes inside strings are data" {
  let doc = @moonvalve.parse(
    "// heading\r\nurl \"https://example.invalid/x\" // tail\nempty \"\"",
  )
  assert_eq(doc.get("url"), Some(@moonvalve.Text("https://example.invalid/x")))
  assert_eq(doc.get("empty"), Some(@moonvalve.Text("")))
}

///|
test "unicode keys and quoted whitespace" {
  let doc = @moonvalve.parse("\"游戏 🎮\" { \"标题\" \"Moon Harbor\" }")
  assert_eq(
    doc.lookup(["游戏 🎮", "标题"]),
    Some(@moonvalve.Text("Moon Harbor")),
  )
}

///|
test "canonical round trip keeps duplicate keys and escaped text" {
  let source = "\"root\" { \"tag\" \"one\" \"tag\" \"two\" \"path\" \"D:\\\\SteamLibrary\" \"line\" \"a\\nb\\t\\\"c\" }"
  let before = @moonvalve.parse(source)
  let rendered = @moonvalve.stringify(before)
  assert_eq(@moonvalve.parse(rendered), before)
  assert_eq(@moonvalve.stringify(@moonvalve.parse(rendered)), rendered)
}

///|
test "literal mode does not decode Windows path escapes" {
  let options = {
    ..@moonvalve.ParseOptions::default(),
    escape_sequences: false,
  }
  let doc = @moonvalve.parse("path \"C:\\temp\\new\"", options~)
  assert_eq(doc.get("path"), Some(@moonvalve.Text("C:\\temp\\new")))
}

///|
test "top level duplicates can be queried without loss" {
  let doc = @moonvalve.parse("key a key b")
  assert_eq(doc.get_all("key"), [@moonvalve.Text("a"), @moonvalve.Text("b")])
  assert_eq(doc.get("key"), Some(@moonvalve.Text("a")))
  assert_eq(doc.get("KEY"), None)
  assert_eq(doc.lookup(["key", "child"]), None)
  assert_eq(doc.lookup([]), Some(@moonvalve.Object(doc.entries)))
}

///|
fn expect_parse_error(
  input : String,
  code : String,
  options? : @moonvalve.ParseOptions = @moonvalve.ParseOptions::default(),
) -> @moonvalve.Diagnostic raise {
  try @moonvalve.parse(input, options~) catch {
    @moonvalve.ParseError(d) => {
      assert_eq(d.code, code)
      d
    }
  } noraise {
    _ => fail("Expected parse error: \{code}")
  }
}

///|
test "structured errors identify missing values with CRLF positions" {
  let d = expect_parse_error("root {\r\n  key\r\n}", "missing_value")
  assert_eq(d.line, 3)
  assert_eq(d.column, 1)
}

///|
test "malformed inputs and unsupported semantics are rejected" {
  let cases = [
    ("root { key value", "unclosed_object"),
    ("}", "unexpected_close"),
    ("root \"unterminated", "unterminated_string"),
    ("key", "missing_value"),
    ("#include other.vdf", "unsupported_directive"),
    ("#base other.vdf", "unsupported_directive"),
    ("key value [$WIN32]", "unsupported_conditional"),
    ("key \"bad\\q\"", "unknown_escape"),
    ("key ab\"cd", "unexpected_quote"),
  ]
  for (input, code) in cases {
    ignore(expect_parse_error(input, code))
  }
}

///|
test "depth and global entry limits include nested objects" {
  let options = { ..@moonvalve.ParseOptions::default(), max_depth: 1, }
  ignore(expect_parse_error("a { b {} }", "depth_limit", options~))
  let options = { ..options, max_entries: 2, }
  ignore(expect_parse_error("a { b c } d e", "entry_limit", options~))
}

///|
test "input and token limits are enforced at boundaries" {
  let options = { ..@moonvalve.ParseOptions::default(), max_input_chars: 3, }
  assert_eq(@moonvalve.parse("a b", options~).entries.length(), 1)
  ignore(expect_parse_error("a bb", "input_limit", options~))
  let options = { ..@moonvalve.ParseOptions::default(), max_token_chars: 1, }
  assert_eq(@moonvalve.parse("a b", options~).entries.length(), 1)
  ignore(expect_parse_error("aa b", "token_limit", options~))
}

///|
test "invalid parser limits fail before reading input" {
  let options = { ..@moonvalve.ParseOptions::default(), max_depth: 257, }
  ignore(expect_parse_error("", "invalid_options", options~))
}

///|
test "leading BOM is accepted and CR-only diagnostics count lines" {
  let bom = String::from_array([(0xFEFF).to_char().unwrap()])
  assert_eq(
    @moonvalve.parse(bom + "key value").get("key"),
    Some(@moonvalve.Text("value")),
  )
  let d = expect_parse_error("root {\rkey\r}", "missing_value")
  assert_eq(d.line, 3)
  assert_eq(d.column, 1)
}

///|
test "zero budgets allow empty input and reject the first entry" {
  let options = { ..@moonvalve.ParseOptions::default(), max_entries: 0, }
  assert_eq(@moonvalve.parse("", options~).entries.length(), 0)
  ignore(expect_parse_error("k v", "entry_limit", options~))
  let options = { ..options, max_entries: 1, max_token_chars: 0, }
  assert_eq(@moonvalve.parse("\"\" \"\"", options~).entries.length(), 1)
  ignore(expect_parse_error("k v", "token_limit", options~))
}

///|
test "NUL text and a trailing escape are rejected" {
  let nul = String::from_array([(0).to_char().unwrap()])
  ignore(expect_parse_error("k \"a" + nul + "b\"", "nul_character"))
  ignore(expect_parse_error("k \"abc\\", "unterminated_string"))
}

///|
test "diagnostic offsets count Unicode scalars rather than UTF16 units" {
  let d = expect_parse_error("🎮 x }", "unexpected_close")
  assert_eq(d.offset, 4)
  assert_eq(d.column, 5)
}
