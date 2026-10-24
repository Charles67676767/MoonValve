///|
fn kv3_header_text() -> String {
  "<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n"
}

///|
test "KV3 parses typed arrays numbers flags blobs and preserves large integers" {
  let text = kv3_header_text() +
    "{ name = \"Moon\" enabled = true missing = null n = 18446744073709551615 min = -9223372036854775808 position = [1.0, -2e3, 0,] model = resource:\"models/moon.vmdl\" blob = #[00 ff 12] }"
  let document = @moonvalve.parse_kv3(text)
  guard document.root is @moonvalve.KV3Object(entries) else {
    fail("Expected object")
  }
  assert_eq(entries[3].value, @moonvalve.KV3Integer("18446744073709551615"))
  assert_eq(entries[4].value, @moonvalve.KV3Integer("-9223372036854775808"))
  assert_eq(
    entries[6].value,
    @moonvalve.KV3Flag("resource", @moonvalve.KV3String("models/moon.vmdl")),
  )
  assert_eq(@moonvalve.parse_kv3(@moonvalve.stringify_kv3(document)), document)
  assert_eq(
    @moonvalve.kv3_from_json(@moonvalve.kv3_to_json(document)),
    document,
  )
}

///|
test "KV3 single quotes multiline comments and special floats roundtrip semantically" {
  let text = kv3_header_text() +
    "{ // line comment\n name = 'Moon' /* block */ text = \"\"\"\nline one\n中文😀\n\"\"\"\n values = [nan, inf, -inf] flag = panorama|[true, false] }"
  let doc = @moonvalve.parse_kv3(text)
  guard doc.root is @moonvalve.KV3Object(entries) else {
    fail("Expected object")
  }
  assert_eq(entries[1].value, @moonvalve.KV3String("line one\n中文😀"))
  assert_eq(@moonvalve.parse_kv3(@moonvalve.stringify_kv3(doc)), doc)
}

///|
test "KV3 accepts scalar roots headerless mode and custom format identifiers" {
  for
    text in ["null", "\"Moon\"", "[1,2,3]", "#[ff]", "resource:{name=\"Moon\"}"] {
    let doc = @moonvalve.parse_kv3(text, allow_headerless=true)
    assert_eq(doc.header, None)
    assert_eq(
      @moonvalve.parse_kv3(@moonvalve.stringify_kv3(doc), allow_headerless=true),
      doc,
    )
  }
  let header = kv3_header_text().replace_all(
    old="format:generic",
    new="format:custom",
  )
  assert_eq(
    @moonvalve.parse_kv3(header + "null").header.unwrap().format_name,
    "custom",
  )
}

///|
test "KV3 rejects invalid headers duplicate keys malformed blobs numeric overflow and trailing data" {
  for
    body in [
      "{a=1 a=2}", "{a=unknown}", "[1 2]", "#[0011]", "#[0g]", "18446744073709551616",
      "-9223372036854775809", "1e9999", "{a=resource:localize:\"x\"}", "null null",
      "/* unclosed",
    ] {
    try @moonvalve.parse_kv3(kv3_header_text() + body) catch {
      _ => ()
    } noraise {
      _ => fail("Expected rejected KV3: " + body)
    }
  }
  for
    text in [
      "null",
      kv3_header_text().replace_all(old="encoding:text", new="encoding:binary") +
      "null",
      kv3_header_text().replace_all(old="7412167c", new="00000000") + "null",
    ] {
    try @moonvalve.parse_kv3(text) catch {
      _ => ()
    } noraise {
      _ => fail("Expected invalid header")
    }
  }
}

///|
test "KV3 resource limits and located diagnostics are enforced" {
  try @moonvalve.parse_kv3(kv3_header_text() + "{\n name = }") catch {
    @moonvalve.ParseError(d) => {
      assert_eq(d.line, 3)
      assert_true(d.column >= 9)
    }
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected syntax error")
  }
  for
    options in [
      @moonvalve.ParseOptions::{
        ..@moonvalve.ParseOptions::default(),
        max_entries: 1,
      },
      @moonvalve.ParseOptions::{
        ..@moonvalve.ParseOptions::default(),
        max_depth: 0,
      },
      @moonvalve.ParseOptions::{
        ..@moonvalve.ParseOptions::default(),
        max_token_chars: 3,
      },
    ] {
    try
      @moonvalve.parse_kv3(kv3_header_text() + "{name=\"Moon\"}", options~)
    catch {
      _ => ()
    } noraise {
      _ => fail("Expected limit")
    }
  }
}
