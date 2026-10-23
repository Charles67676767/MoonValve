///|
test "writer round trips quotes control characters and Unicode" {
  for
    text in [
      "", "plain", "a\"b", "C:\\temp\\new", "a\nb\rc\td", "🎮 中文", "// comment",
      "{}[]",
    ] {
    let doc = @moonvalve.Document::{
      entries: [{ key: text, value: @moonvalve.Text(text), }],
    }
    assert_eq(@moonvalve.parse(@moonvalve.stringify(doc)), doc)
  }
}

///|
test "writer rejects reserved directive keys instead of emitting ambiguous text" {
  let doc = @moonvalve.Document::{
    entries: [{ key: "#include", value: @moonvalve.Text("file"), }],
  }
  try @moonvalve.stringify(doc) catch {
    @moonvalve.InvalidDocument(_) => ()
  } noraise {
    _ => fail("Expected reserved key to be rejected")
  }
}

///|
test "JSON export retains duplicate entries and empty objects" {
  let doc = @moonvalve.parse("k one k two empty {}")
  assert_eq(
    doc.to_json(),
    Json::array([
      Json::object({ "key": Json::string("k"), "value": Json::string("one") }),
      Json::object({ "key": Json::string("k"), "value": Json::string("two") }),
      Json::object({ "key": Json::string("empty"), "value": Json::array([]) }),
    ]),
  )
}

///|
test "wide generated documents retain order under canonical round trip" {
  let entries : Array[@moonvalve.Entry] = []
  for i in 0..<200 {
    entries.push({
      key: "tag",
      value: @moonvalve.Object([
        { key: "index", value: @moonvalve.Text(i.to_string()), },
        { key: "text", value: @moonvalve.Text("line\nquote\"slash\\🎮"), },
      ]),
    })
  }
  let doc = @moonvalve.Document::{ entries, }
  assert_eq(@moonvalve.parse(@moonvalve.stringify(doc)), doc)
}

///|
test "writer rejects NUL and bounds externally constructed deep trees" {
  let nul = String::from_array([(0).to_char().unwrap()])
  let doc = @moonvalve.Document::{
    entries: [{ key: "k", value: @moonvalve.Text(nul), }],
  }
  try @moonvalve.stringify(doc) catch {
    @moonvalve.InvalidDocument(_) => ()
  } noraise {
    _ => fail("Expected NUL rejection")
  }
  let mut value = @moonvalve.Text("leaf")
  for _ in 0..<130 {
    value = @moonvalve.Object([{ key: "nested", value, }])
  }
  let doc = @moonvalve.Document::{ entries: [{ key: "root", value, }], }
  try @moonvalve.stringify(doc) catch {
    @moonvalve.InvalidDocument(_) => ()
  } noraise {
    _ => fail("Expected writer depth rejection")
  }
}
