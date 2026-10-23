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
test "base occurrence merge retains local values and ASCII case rules" {
  let files : Map[String, String] = {
    "main": "#base defaults Key own key { a local } Ä upper",
    "defaults": "KEY ignored kEy { a base b default } key third ä lower",
  }
  let doc = @moonvalve.load_resolved("main", p => files.get(p).unwrap())
  assert_eq(doc.entries.map(e => e.key), ["Key", "key", "Ä", "key", "ä"])
  assert_eq(doc.entries[0].value, @moonvalve.Text("own"))
  assert_eq(
    doc.entries[1].value,
    @moonvalve.Object([
      { key: "a", value: @moonvalve.Text("local"), },
      { key: "b", value: @moonvalve.Text("default"), },
    ]),
  )
}

///|
test "large base merge keeps stable order without repeated whole-array scans" {
  let current = StringBuilder()
  let defaults = StringBuilder()
  current.write_string("#base defaults ")
  for i in 0..<10000 {
    current.write_string("key\{i} own ")
    defaults.write_string("KEY\{i} default extra\{i} value ")
  }
  let doc = @moonvalve.load_resolved("main", path => {
    if path == "main" {
      current.to_string()
    } else {
      defaults.to_string()
    }
  })
  assert_eq(doc.entries.length(), 20000)
  assert_eq(doc.entries[9999].key, "key9999")
  assert_eq(doc.entries[10000].key, "extra0")
  assert_eq(doc.get("key9999"), Some(@moonvalve.Text("own")))
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
