///|
fn demonstrate() -> Unit raise {
  let path : Array[@valve.Selector] = [
    { key: "root", occurrence: 0, },
    { key: "tag", occurrence: 1, },
  ]
  let original = "// retain this comment\nroot { tag one tag two }\n"
  let edited = @valve.parse_preserving(original).edit(
    path,
    @valve.Replace(@valve.Text("three")),
  )
  println(edited.text())
  assert_eq(
    @valve.parse_json_document(edited.document().to_json().stringify()),
    edited.document(),
  )
  let options = {
    ..@valve.ParseOptions::default(),
    conditions: Some(["WIN32"]),
  }
  let conditional = @valve.parse(
    "platform windows [$WIN32] platform linux [$LINUX]",
    options~,
  )
  assert_eq(conditional.get_all("platform"), [@valve.Text("windows")])
  let files : Map[String, String] = {
    "cfg/main.vdf": "root { local yes } #base ../defaults.vdf",
    "defaults.vdf": "root { default yes }",
  }
  let resolved = @valve.load_resolved("cfg/main.vdf", path => {
    files.get(path).unwrap()
  })
  println(@valve.stringify(resolved))
  let typed : Array[@valve.BinaryEntry] = [
    { key: "id", value: @valve.UInt64Value(18446744073709551615UL), },
    { key: "label", value: @valve.WideString("中文😀"), },
  ]
  let bytes = @valve.encode_binary(typed)
  assert_eq(@valve.decode_binary(bytes), typed)
  println("Binary roundtrip: \{bytes.length()} bytes")
}

///|
fn main {
  demonstrate() catch {
    error => println(error.to_string())
  }
}
