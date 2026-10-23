///|
test "all-path query traverses duplicate parents and visitor can skip subtrees" {
  let doc = @moonvalve.parse("r { x 1 x 2 } r { x 3 } leaf value")
  assert_eq(doc.lookup_all(["r", "x"]), [
    @moonvalve.Text("1"),
    @moonvalve.Text("2"),
    @moonvalve.Text("3"),
  ])
  assert_eq(
    doc.lookup_at([{ key: "r", occurrence: 1, }, { key: "x", occurrence: 0, }]),
    @moonvalve.Text("3"),
  )
  let found = doc.find("x")
  assert_eq(found.length(), 3)
  assert_eq(found[1].path, [
    { key: "r", occurrence: 0, },
    { key: "x", occurrence: 1, },
  ])
  let visited : Array[String] = []
  doc.walk((path, _) => {
    visited.push(path[path.length() - 1].key)
    false
  })
  assert_eq(visited, ["r", "r", "leaf"])
}

///|
test "typed access reports complete paths without rounding or permissive conversion" {
  let doc = @moonvalve.parse(
    "n 9223372036854775807 b 1 d 1.25 bad yes huge 9223372036854775808",
  )
  assert_eq(
    doc.read_int64([{ key: "n", occurrence: 0, }]),
    9223372036854775807L,
  )
  assert_eq(doc.read_bool([{ key: "b", occurrence: 0, }]), true)
  assert_eq(doc.read_double([{ key: "d", occurrence: 0, }]), 1.25)
  let path : Array[@moonvalve.Selector] = [{ key: "huge", occurrence: 0, }]
  try doc.read_int64(path) catch {
    @moonvalve.InvalidAccess(p, _) => assert_eq(p, path)
  } noraise {
    _ => fail("Expected overflow")
  }
  try doc.read_bool([{ key: "bad", occurrence: 0, }]) catch {
    @moonvalve.InvalidAccess(_, _) => ()
  } noraise {
    _ => fail("Expected boolean error")
  }
}

///|
test "transaction paths are sequential and failures preserve the original" {
  let original = @moonvalve.parse_preserving("// keep\nk one k two\n")
  let changes = @moonvalve.changes_from_json(
    @json.parse(
      "[{\"path\":[{\"key\":\"k\",\"occurrence\":0}],\"op\":\"remove\"},{\"path\":[{\"key\":\"k\",\"occurrence\":0}],\"op\":\"replace\",\"value\":\"three\"}]",
    ),
  )
  assert_eq(original.apply(changes).document().get_all("k"), [
    @moonvalve.Text("three"),
  ])
  let invalid : Array[@moonvalve.Change] = [
    changes[0],
    {
      path: [{ key: "missing", occurrence: 0, }],
      operation: @moonvalve.Remove,
    },
  ]
  try original.apply(invalid) catch {
    _ => ()
  } noraise {
    _ => fail("Expected transaction failure")
  }
  assert_eq(original.text(), "// keep\nk one k two\n")
  assert_eq(
    original.document().apply(changes),
    original.apply(changes).document(),
  )
}
