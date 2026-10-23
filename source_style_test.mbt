///|
test "source keeps all conditional branches and root references verbatim" {
  let original = "#base defaults.vdf\r\nroot\r\n{\r\n\tmode win [$WIN32]\r\n\tmode linux [!$WIN32]\r\n}\r\n"
  let source = @moonvalve.parse_preserving(original)
  assert_eq(source.document().lookup_all(["root", "mode"]), [
    @moonvalve.Text("win"),
    @moonvalve.Text("linux"),
  ])
  let changed = source.edit(
    [{ key: "root", occurrence: 0, }, { key: "mode", occurrence: 1, }],
    @moonvalve.Replace(@moonvalve.Text("unix")),
  )
  assert_eq(
    changed.text(),
    original.replace_all(old="mode linux", new="mode unix"),
  )
  let removed = changed.edit(
    [{ key: "root", occurrence: 0, }, { key: "mode", occurrence: 0, }],
    @moonvalve.Remove,
  )
  assert_true(!removed.text().contains("[$WIN32]"))
  assert_true(removed.text().has_prefix("#base defaults.vdf\r\n"))
}

///|
test "source insert adopts tabs CRLF and existing scalar quotation" {
  let source = @moonvalve.parse_preserving(
    "root\r\n{\r\n\ta one\r\n\tb \"two\"\r\n}\r\n",
  )
  let changed = source.edit(
    [{ key: "root", occurrence: 0, }],
    @moonvalve.Insert(1, { key: "new", value: @moonvalve.Text("value"), }),
  )
  assert_true(changed.text().contains("\r\n\tnew value\r\n\tb"))
  let replaced = source.edit(
    [{ key: "root", occurrence: 0, }, { key: "a", occurrence: 0, }],
    @moonvalve.Replace(@moonvalve.Text("three")),
  )
  assert_true(replaced.text().contains("\ta three\r\n"))
  let quoted = source.edit(
    [{ key: "root", occurrence: 0, }, { key: "b", occurrence: 0, }],
    @moonvalve.Replace(@moonvalve.Text("three")),
  )
  assert_true(quoted.text().contains("\tb \"three\"\r\n"))
}

///|
test "literal source edits preserve backslashes and condition evaluation is separate" {
  let options = {
    ..@moonvalve.ParseOptions::default(),
    escape_sequences: false,
  }
  let source = @moonvalve.parse_preserving(
    "path \"C:\\games\" platform win [$WIN32] platform linux [$LINUX]",
    options~,
  )
  assert_eq(source.evaluate(["WIN32"]).get_all("platform"), [
    @moonvalve.Text("win"),
  ])
  let changed = source.edit(
    [{ key: "path", occurrence: 0, }],
    @moonvalve.Replace(@moonvalve.Text("D:\\new")),
  )
  assert_true(changed.text().has_prefix("path \"D:\\new\""))
}
