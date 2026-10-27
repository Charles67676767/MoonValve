///|
test "workspace query selection, order, complete edits and rollback" {
  let files : Map[String, String] = {
    "z.vdf": "r { path old/z }",
    "a.vdf": "// keep\r\nr { path old/a path old/b }",
    "other.vdf": "r { path other }",
  }
  let workspace = @moonvalve.new_workspace(files)
  let rows = workspace.select("/r/path?^=\"old/\"")
  assert_true(rows.stringify().has_prefix("[{\"file\":\"a.vdf\""))
  let changed = workspace.edit_query(
    "/r/path?^=\"old/\"",
    @moonvalve.ReplacePrefix("old/", "new/"),
  )
  assert_eq(changed.files()["a.vdf"], "// keep\r\nr { path new/a path new/b }")
  assert_eq(changed.files()["other.vdf"], files["other.vdf"])
  assert_eq(workspace.files(), files)
  let selected = workspace.edit_query("/r/path", @moonvalve.SetText("yes"), files=[
    "z.vdf",
  ])
  assert_eq(selected.files()["a.vdf"], files["a.vdf"])
  assert_true(
    try {
      workspace.edit_query("/r/path", @moonvalve.ReplacePrefix("old/", "new/"))
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(workspace.files(), files)
  assert_true(
    try {
      workspace.select("/**", files=["missing"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      workspace.select("/**", files=["z.vdf", "z.vdf"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  let plan = @json.parse(
    "[{\"op\":\"query\",\"expression\":\"/r/path\",\"operation\":{\"op\":\"replace\",\"value\":\"yes\"},\"files\":[\"z.vdf\"]}]",
  )
  assert_eq(workspace.apply(plan).files(), selected.files())
}

///|
test "workspace files use lexical rather than string-length ordering" {
  let workspace = @moonvalve.new_workspace({
    "z": "k v",
    "config/base.vdf": "k v",
  })
  guard workspace.select("/k") is Array(rows) else { fail("Expected rows") }
  assert_eq(json_field(rows[0], "file"), Json::string("config/base.vdf"))
}
