///|
fn workflow_kv3(body : String) -> String {
  "<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n" +
  body
}

///|
test "mixed workspace keeps KV1 references and typed KV3 queries independent" {
  let raw = workflow_kv3(
    "// exact\n{ id=18446744073709551615 path=resource:\"old/moon.vmat\" }",
  )
  let files : Map[String, String] = {
    "main.vdf": "#base base.vdf\nr {k one k two}",
    "base.vdf": "r {extra yes}",
    "a.kv3": raw,
    "sub/b.kv3": raw,
  }
  let workspace = @moonvalve.new_workspace(files)
  assert_eq(workspace.files().length(), 4)
  assert_true(workspace.select("/**/k") is Array(rows) && rows.length() == 1)
  assert_true(
    workspace.select_kv3("/**?type=integer&>9007199254740993") is Array(rows) &&
    rows.length() == 2,
  )
  let edited = workspace.edit_query_kv3(
    "/**?flag=resource",
    @moonvalve.KV3ReplacePrefix("old/", "new/"),
  )
  assert_true(edited.files()["a.kv3"].contains("resource:\"new/moon.vmat\""))
  assert_eq(edited.files()["main.vdf"], files["main.vdf"])
  assert_eq(workspace.files()["a.kv3"], raw)
  assert_true(
    edited.rename_file("base.vdf", "nested/base.vdf").files()["main.vdf"].contains(
      "nested/base.vdf",
    ),
  )
  assert_eq(
    edited.copy_file("a.kv3", "copy.kv3").files()["copy.kv3"],
    edited.files()["a.kv3"],
  )
  assert_eq(edited.remove_file("a.kv3").files().length(), 3)
  assert_eq(
    edited.rename_file("a.kv3", "c.kv3").files()["c.kv3"],
    edited.files()["a.kv3"],
  )
  let failed = try {
    workspace.select_kv3("/**", files=["main.vdf"]) |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_true(
    try {
      workspace.select("/**", files=["a.kv3"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "typed workspace batch rejects partial changes and mixed plans retain entry" {
  let raw = workflow_kv3("{path=resource:\"old/a\"}")
  let workspace = @moonvalve.new_workspace({
    "a.kv3": raw,
    "b.kv3": workflow_kv3("{path=1}"),
  })
  assert_true(
    try {
      workspace.edit_query_kv3(
        "/path",
        @moonvalve.KV3ReplacePrefix("old/", "new/"),
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(workspace.files()["a.kv3"], raw)
  let snapshot = Json::object({
    "format": Json::string("moonvalve-project-v1"),
    "source": Json::string("a.kv3"),
    "files": workspace.to_json(),
  })
  let plan : Json = [
    {
      "op": "kv3-query",
      "expression": "/**?flag=resource",
      "files": [],
      "operation": { "op": "replace-prefix", "from": "old/", "to": "new/" },
    },
    { "op": "rename", "from": "a.kv3", "to": "next.kv3" },
  ]
  let result = @moonvalve.edit_workspace_snapshot(snapshot, plan)
  assert_true(
    result is Object(fields) &&
    fields.get("source") == Some(Json::string("next.kv3")),
  )
  assert_true(
    @moonvalve.query_workspace_kv3_snapshot(result, "/path") is Array(rows) &&
    rows.length() == 2,
  )
  assert_true(@moonvalve.export_project_zip(result).length() > 0)
}

///|
test "KV1 whitespace format retains conditions directives duplicates and comment text" {
  let text = "\uFEFF// intro\r\n #base base.vdf\r\n r { tag one [$WIN32] tag two [$LINUX] child {x \"a  b\"} } // tail\r\n"
  let source = @moonvalve.parse_preserving(text)
  let formatted = source.format_preserving()
  assert_eq(formatted.document(), source.document())
  assert_eq(formatted.format_preserving().text(), formatted.text())
  for
    token in [
      "\uFEFF// intro", "#base base.vdf", "[$WIN32]", "[$LINUX]", "\"a  b\"", "// tail",
    ] {
    assert_true(formatted.text().contains(token))
  }
  assert_true(formatted.text().contains("\r\n  tag one"))
  let literal = @moonvalve.parse_preserving("r {path \"C:\\Games\\A\"}", options={
    ..@moonvalve.ParseOptions::default(),
    escape_sequences: false,
  })
  assert_true(literal.format_preserving().text().contains("C:\\Games\\A"))
}

///|
test "KV3 whitespace format preserves multiline values blobs flags comments and exact numeric spelling" {
  let body = "/* intro */\n{ a=000255 b=+1.0 c=resource: \"a//b\" arr=[1, /*keep*/ 2,] data=#[00 ff] text=\"\"\"\n  literal { [ // unchanged\n\"\"\" //tail\n }"
  let source = @moonvalve.parse_kv3_preserving(workflow_kv3(body))
  let formatted = source.format_preserving()
  assert_eq(formatted.document(), source.document())
  assert_eq(formatted.format_preserving().text(), formatted.text())
  for
    token in [
      "/* intro */", "000255", "+1.0", "resource: \"a//b\"", "/*keep*/", "#[00 ff]",
      "\"\"\"\n  literal { [ // unchanged\n\"\"\"", "//tail",
    ] {
    assert_true(formatted.text().contains(token))
  }
  assert_true(formatted.text().contains("\n  a = 000255"))
  let bare = @moonvalve.parse_kv3_preserving("[1,2]", allow_headerless=true).format_preserving()
  assert_eq(bare.format_preserving().text(), bare.text())
}
