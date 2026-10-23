///|
test "edit selects an individual duplicate and leaves input unchanged" {
  let before = @moonvalve.parse("root { tag one tag two name demo }")
  let path = [
    @moonvalve.Selector::{ key: "root", occurrence: 0, },
    { key: "tag", occurrence: 1, },
  ]
  let after = before.edit(path, @moonvalve.Replace(@moonvalve.Text("changed")))
  assert_eq(before.lookup(["root", "tag"]), Some(@moonvalve.Text("one")))
  assert_eq(
    @moonvalve.stringify(before),
    @moonvalve.stringify(@moonvalve.parse("root { tag one tag two name demo }")),
  )
  guard after.get("root") is Some(@moonvalve.Object(entries)) else {
    fail("object")
  }
  assert_eq(entries[0].value, @moonvalve.Text("one"))
  assert_eq(entries[1].value, @moonvalve.Text("changed"))
  assert_eq(@moonvalve.parse(@moonvalve.stringify(after)), after)
}

///|
test "insert rename and remove preserve sibling ordering" {
  let doc = @moonvalve.parse("a x a y b z")
  let renamed = doc.edit([{ key: "a", occurrence: 1, }], @moonvalve.Rename("c"))
  let removed = renamed.edit([{ key: "a", occurrence: 0, }], @moonvalve.Remove)
  let inserted = removed.edit(
    [],
    @moonvalve.Insert(1, { key: "new", value: @moonvalve.Text("v"), }),
  )
  assert_eq(inserted.entries.map(e => e.key), ["c", "new", "b"])
  assert_eq(doc.entries.map(e => e.key), ["a", "a", "b"])
}

///|
test "edit invalid paths and root operations fail" {
  let doc = @moonvalve.parse("a x")
  let cases : Array[(Array[@moonvalve.Selector], @moonvalve.Edit)] = [
    ([], @moonvalve.Remove),
    ([], @moonvalve.Rename("x")),
    ([], @moonvalve.Replace(@moonvalve.Text("x"))),
    ([], @moonvalve.Insert(-1, { key: "b", value: @moonvalve.Text("x"), })),
    ([{ key: "a", occurrence: 1, }], @moonvalve.Remove),
    ([{ key: "a", occurrence: -1, }], @moonvalve.Remove),
    (
      [{ key: "a", occurrence: 0, }, { key: "b", occurrence: 0, }],
      @moonvalve.Remove,
    ),
  ]
  for (path, operation) in cases {
    try doc.edit(path, operation) catch {
      @moonvalve.InvalidEdit(_) => ()
    } noraise {
      _ => fail("Expected invalid edit")
    }
  }
}
