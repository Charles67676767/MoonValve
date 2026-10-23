///|
test "include appends and base recursively fills missing fields" {
  let files : Map[String, String] = {
    "cfg/main.vdf": "#include extra.vdf root { local yes nested { a own } } #base ../base.vdf",
    "cfg/extra.vdf": "root { included yes } tail value",
    "base.vdf": "root { local no missing default nested { a base b value } } root { default2 yes }",
  }
  let doc = @moonvalve.load_resolved("cfg/./main.vdf", p => {
    files.get(p).unwrap()
  })
  assert_eq(doc.entries.map(e => e.key), ["root", "root", "tail"])
  assert_eq(doc.lookup(["root", "local"]), Some(@moonvalve.Text("yes")))
  assert_eq(doc.lookup(["root", "missing"]), Some(@moonvalve.Text("default")))
  assert_eq(doc.lookup(["root", "nested", "b"]), Some(@moonvalve.Text("value")))
}

///|
test "nested directive-like keys are ordinary data" {
  let doc = @moonvalve.parse("root { #include literal }")
  assert_eq(@moonvalve.parse(@moonvalve.stringify(doc)), doc)
}

///|
test "file cycles path escapes and cumulative budgets are rejected" {
  let files : Map[String, String] = { "a": "#include b", "b": "#include ./a" }
  try @moonvalve.load_resolved("a", p => files.get(p).unwrap()) catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected cycle")
  }
  for
    text in [
      "#include ../escape", "#include /absolute", "#include C:/absolute", "#include {}",
    ] {
    try @moonvalve.load_resolved("a", _ => text) catch {
      @moonvalve.InvalidReference(_) => ()
      error => fail(error.to_string())
    } noraise {
      _ => fail("Expected invalid reference")
    }
  }
  let files : Map[String, String] = { "a": "#include b x y", "b": "m n" }
  let options = { ..@moonvalve.ParseOptions::default(), max_entries: 2, }
  try
    @moonvalve.load_resolved("a", p => files.get(p).unwrap(), options~)
  catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected global count limit")
  }
  try
    @moonvalve.load_resolved("a", p => files.get(p).unwrap(), max_files=1)
  catch {
    @moonvalve.InvalidReference(_) => ()
    error => fail(error.to_string())
  } noraise {
    _ => fail("Expected file limit")
  }
}
