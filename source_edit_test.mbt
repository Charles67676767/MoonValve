///|
test "source edits preserve BOM comments CRLF whitespace and duplicate occurrence" {
  let original = "\uFEFF// header\r\nroot\t{\r\n  k  one // first\r\n\tk\t\"中文😀\" // second\r\n}\r\n// tail"
  let parsed = @moonvalve.parse_preserving(original)
  let path : Array[@moonvalve.Selector] = [
    { key: "root", occurrence: 0, },
    { key: "k", occurrence: 1, },
  ]
  let edited = parsed.edit(path, @moonvalve.Replace(@moonvalve.Text("changed")))
  assert_eq(
    edited.text(),
    original.replace_all(old="\"中文😀\"", new="\"changed\""),
  )
  assert_eq(parsed.text(), original)
  let renamed = edited.edit(path, @moonvalve.Rename("new key"))
  assert_eq(
    renamed.text(),
    edited.text().replace_all(old="\tk\t", new="\t\"new key\"\t"),
  )
}

///|
test "source insertion removal and object replacement are reparsed" {
  let source = @moonvalve.parse_preserving("// keep\na { x 1 } // end")
  let path : Array[@moonvalve.Selector] = [{ key: "a", occurrence: 0, }]
  let inserted = source.edit(
    path,
    @moonvalve.Insert(0, { key: "x", value: @moonvalve.Text("0"), }),
  )
  assert_eq(inserted.document().lookup(["a", "x"]), Some(@moonvalve.Text("0")))
  assert_eq(inserted.text().has_prefix("// keep\na {"), true)
  assert_eq(inserted.text().has_suffix("} // end"), true)
  let removed = inserted.edit(
    [{ key: "a", occurrence: 0, }, { key: "x", occurrence: 1, }],
    @moonvalve.Remove,
  )
  assert_eq(removed.document().lookup(["a", "x"]), Some(@moonvalve.Text("0")))
  let replaced = removed.edit(path, @moonvalve.Replace(@moonvalve.Object([])))
  assert_eq(replaced.text(), "// keep\na {\n} // end")
  let appended = replaced.edit(
    [],
    @moonvalve.Insert(1, { key: "b", value: @moonvalve.Text("2"), }),
  )
  assert_eq(appended.document().get("b"), Some(@moonvalve.Text("2")))
}

///|
test "source edit failures leave original untouched" {
  let source = @moonvalve.parse_preserving("a b")
  try
    source.edit([{ key: "missing", occurrence: 0, }], @moonvalve.Remove)
  catch {
    @moonvalve.InvalidEdit(_) => ()
    other => fail(other.to_string())
  } noraise {
    _ => fail("Expected missing selector")
  }
  assert_eq(source.text(), "a b")
}
