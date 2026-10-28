///|
fn export_snapshot(
  files : Map[String, Json],
  source? : String = "main.vdf",
) -> Json {
  Json::object({
    "format": Json::string("moonvalve-project-v1"),
    "source": Json::string(source),
    "files": Json::object(files),
  })
}

///|
test "project ZIP export validates first and preserves original text bytes" {
  let snapshot = export_snapshot({
    "main.vdf": Json::string("//keep\r\nr {k v}"),
    "配置/默认.vdf": Json::string("r {}"),
  })
  let files = @moonvalve.project_export_files(snapshot)
  assert_eq(files["main.vdf"], "//keep\r\nr {k v}")
  let bytes = @moonvalve.export_project_zip(snapshot)
  assert_eq(bytes[0:4].to_owned(), b"PK\x03\x04")
  assert_eq(bytes[6:8].to_owned(), b"\x00\x08")
  assert_eq(
    bytes[bytes.length() - 22:bytes.length() - 18].to_owned(),
    b"PK\x05\x06",
  )
  assert_eq(@moonvalve.export_project_zip(snapshot), bytes)
}

///|
test "project export rejects traversal device names case and file-directory collisions" {
  for
    name in [
      "../outside", "/absolute", "C:/drive", "a\\b", "con.txt", "dir/NUL", "a.",
      "a ", "a\nfile", "dir//file", "./a",
    ] {
    let files : Map[String, Json] = { "main.vdf": Json::string("r {}") }
    files[name] = Json::string("r {}")
    assert_true(
      try {
        @moonvalve.export_project_zip(export_snapshot(files)) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  for
    files in [
      { "main.vdf": Json::string("r {}"), "Main.vdf": Json::string("r {}") },
      {
        "main.vdf": Json::string("r {}"),
        "folder": Json::string("r {}"),
        "folder/a": Json::string("r {}"),
      },
      { "main.vdf": Json::string("r {broken}") },
    ] {
    assert_true(
      try {
        @moonvalve.project_export_files(export_snapshot(files)) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  assert_true(
    try {
      @moonvalve.project_export_files(
        export_snapshot({ "a": Json::string("r {}") }),
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}
