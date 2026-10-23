///|
test "project origins follow inherited fields includes duplicate pairing and local overrides" {
  let files : Map[String, String] = {
    "main": "#base defaults\n#include extra\nroot { own yes nested { local keep } }",
    "defaults": "root { own no inherited yes nested { other base } }",
    "extra": "root { included yes }",
  }
  let project = @moonvalve.load_project("main", p => files.get(p).unwrap())
  assert_eq(
    project.document,
    @moonvalve.load_resolved("main", p => files.get(p).unwrap()),
  )
  let path : Array[@moonvalve.Selector] = [
    { key: "root", occurrence: 0, },
    { key: "nested", occurrence: 0, },
    { key: "other", occurrence: 0, },
  ]
  let origin = project.origins.iter().find_first(o => o.path == path).unwrap()
  assert_eq(origin.location.source, "defaults")
  assert_eq(origin.location.column, 38)
  assert_eq(
    project.origins
    .iter()
    .find_first(o => o.path == [{ key: "root", occurrence: 1, }])
    .unwrap().location.source,
    "extra",
  )
  assert_eq(project.references.map(e => e.kind), ["include", "base"])
  assert_eq(project.references[0].location.line, 2)
}

///|
test "filtered nested objects and override removal retain exact surviving locations" {
  let text = "r { gone { child no } [$LINUX]\n k old\n x keep\n k = [$WIN32] win\n tail end }"
  let project = @moonvalve.load_project("main", _ => text, options={
    ..@moonvalve.ParseOptions::default(),
    conditions: Some(["WIN32"]),
  })
  assert_eq(
    project.document.entries[0].value.as_object().unwrap().map(e => e.key),
    ["x", "k", "tail"],
  )
  assert_eq(project.origins.length(), 4)
  let origin = project.origins
    .iter()
    .find_first(o => {
      o.path == [{ key: "r", occurrence: 0, }, { key: "k", occurrence: 0, }]
    })
    .unwrap()
  assert_eq(origin.location.line, 4)
  assert_eq(origin.location.column, 2)
  assert_true(
    project.origins
    .iter()
    .all(o => !o.path.any(p => p.key == "gone" || p.key == "child")),
  )
}

///|
test "raw source locations count Unicode scalars and CRLF without filtering duplicate branches" {
  let text = "\uFEFFemoji 😀\r\nroot { k one [$WIN32] k two [$LINUX] }"
  let source = @moonvalve.parse_preserving(text)
  let origins = source.locations("config/main.vdf")
  assert_eq(origins.length(), 4)
  let last = origins[3]
  assert_eq(last.path, [
    { key: "root", occurrence: 0, },
    { key: "k", occurrence: 1, },
  ])
  assert_eq(last.location.line, 2)
  assert_eq(last.location.column, 23)
  assert_eq(
    last.location.offset,
    "\uFEFFemoji 😀\r\nroot { k one [$WIN32] ".char_length(),
  )
}

///|
test "project graph excludes disabled references and reports cycles rather than partial success" {
  let project = @moonvalve.load_project(
    "main",
    _ => "#include missing [$LINUX] root yes",
    options={
      ..@moonvalve.ParseOptions::default(),
      conditions: Some(["WIN32"]),
    },
  )
  assert_eq(project.references.length(), 0)
  try @moonvalve.load_project("main", _ => "#include main") catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected cycle")
  }
}

///|
test "stream writer produces equivalent canonical text without accumulating a tree" {
  let output = StringBuilder()
  let writer = @moonvalve.new_stream_writer(text => output.write_string(text))
  let parser = @moonvalve.new_stream_parser(event => {
    writer.write(event)
    true
  })
  for chunk in ["root { k \"中", "文😀\" k two nested { x ", "y } }"] {
    parser.feed(chunk)
  }
  parser.finish()
  writer.finish()
  assert_eq(
    @moonvalve.parse(output.to_string()),
    @moonvalve.parse("root { k \"中文😀\" k two nested {x y} }"),
  )
  try writer.finish() catch {
    @moonvalve.InvalidDocument(_) => ()
  } noraise {
    _ => fail("Expected closed writer")
  }
}

///|
test "stream writer rejects ambiguous conditions directives and unbalanced or failed sinks" {
  for
    event in [
      @moonvalve.Condition("k", "$WIN32"),
      @moonvalve.Pair("#base", "base"),
      @moonvalve.EndObject,
    ] {
    let writer = @moonvalve.new_stream_writer(_ => ())
    try writer.write(event) catch {
      @moonvalve.InvalidDocument(_) => ()
      error => fail(error.to_string())
    } noraise {
      _ => fail("Expected rejected event")
    }
  }
  let writer = @moonvalve.new_stream_writer(_ => raise Failure("closed sink"))
  try writer.write(@moonvalve.Pair("k", "v")) catch {
    Failure(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected sink failure")
  }
  try writer.finish() catch {
    @moonvalve.InvalidDocument(_) => ()
  } noraise {
    _ => fail("Expected failed writer")
  }
}
