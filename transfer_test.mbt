///|
test "source move carries attached comments conditions and duplicate identity" {
  let text = "// file header\r\nr\r\n{\r\n  // first note\r\n  k one [$WIN32] // trailing note\r\n  k two\r\n  tail done\r\n}\r\n"
  let source = @moonvalve.parse_preserving(text)
  let moved = source.transfer(
    [{ key: "r", occurrence: 0, }, { key: "k", occurrence: 0, }],
    [{ key: "r", occurrence: 0, }],
    3,
  )
  assert_eq(
    moved.document().select("/r/*").map(v => v.value.as_text().unwrap()),
    ["two", "done", "one"],
  )
  assert_true(
    moved
    .text()
    .contains("  // first note\r\n  k one [$WIN32] // trailing note\r\n}"),
  )
  assert_true(moved.text().has_prefix("// file header\r\n"))
  assert_eq(source.text(), text)
}

///|
test "cross object copy reindents syntax without changing multiline strings or nested comments" {
  let text = "r {\n  src {\n    // keep\n    k \"line one\n  line two\"\n  }\n  target {\n  }\n}\n"
  let source = @moonvalve.parse_preserving(text)
  let from : Array[@moonvalve.Selector] = [
    { key: "r", occurrence: 0, },
    { key: "src", occurrence: 0, },
  ]
  let to : Array[@moonvalve.Selector] = [
    { key: "r", occurrence: 0, },
    { key: "target", occurrence: 0, },
  ]
  let copied = source.transfer(from, to, 0, copy=true)
  assert_eq(
    copied.document().lookup(["r", "target", "src", "k"]),
    Some(@moonvalve.Text("line one\n  line two")),
  )
  assert_true(copied.text().contains("    src {\n      // keep"))
  assert_eq(
    copied.document().lookup(["r", "src", "k"]),
    copied.document().lookup(["r", "target", "src", "k"]),
  )
}

///|
test "inline move order uses original boundaries and adjacent moves are noops" {
  let source = @moonvalve.parse_preserving("r { k one k two k three }")
  let parent : Array[@moonvalve.Selector] = [{ key: "r", occurrence: 0, }]
  let first = [..parent, @moonvalve.Selector::{ key: "k", occurrence: 0, }]
  assert_eq(source.transfer(first, parent, 1).text(), source.text())
  let reordered = source.transfer(first, parent, 3)
  assert_eq(
    reordered
    .document()
    .get("r")
    .unwrap()
    .as_object()
    .unwrap()
    .map(e => e.value.as_text().unwrap()),
    ["two", "three", "one"],
  )
  let copy = source.transfer(first, parent, 0, copy=true)
  assert_eq(copy.document().select("/r/k").length(), 4)
}

///|
test "transfer rejects root scalar destination cycles and out of range targets" {
  let source = @moonvalve.parse_preserving("r { child { x y } leaf value }")
  let root : Array[@moonvalve.Selector] = [{ key: "r", occurrence: 0, }]
  for
    target in [
      [..root, @moonvalve.Selector::{ key: "child", occurrence: 0, }],
      [..root, @moonvalve.Selector::{ key: "leaf", occurrence: 0, }],
    ] {
    try source.transfer(root, target, 0) catch {
      @moonvalve.InvalidEdit(_) => ()
      error => fail(error.to_string())
    } noraise {
      _ => fail("Expected invalid transfer")
    }
  }
  try source.transfer([], [], 0) catch {
    @moonvalve.InvalidEdit(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected root rejection")
  }
}
