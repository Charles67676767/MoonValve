///|
test "resource roots use longest explicit prefix and never treat symbolic flags as files" {
  let source = @moonvalve.parse_kv3_preserving(
    workflow_kv3(
      "{a=resource:\"materials/moon.vmat\" b=resource:\"models/moon.vmdl\" c=resource_name:\"name\" d=soundevent:\"event\" e=localize:\"token\" empty=resource:\"\"}",
    ),
  )
  let raw = source.resources()
  assert_eq(raw.length(), 3)
  assert_eq(raw[0].status, "unconfigured")
  assert_eq(raw[2].status, "empty")
  let roots : Array[@moonvalve.ResourceRoot] = [
    { prefix: "", directory: "content", },
    { prefix: "materials/", directory: "sources/materials", },
  ]
  let mapped = source.resources(roots~)
  assert_eq(mapped[0].target, Some("sources/materials/moon.vmat"))
  assert_eq(mapped[1].target, Some("content/models/moon.vmdl"))
  assert_eq(mapped[0].path, ["a"])
  assert_true(
    @moonvalve.resource_references_to_json(mapped)
    .stringify()
    .contains("resolved"),
  )
  let unmapped = source.resources(roots=[
    { prefix: "models/", directory: "content/models", },
  ])
  assert_eq(unmapped[0].status, "unmapped")
  for
    path in ["../outside", "/absolute", "a/../b", "a//b", "C:/outside", "a\\b"] {
    let value = Json::string(path).stringify()
    let s = @moonvalve.parse_kv3_preserving(
      workflow_kv3("{a=resource:" + value + "}"),
    )
    assert_eq(s.resources(roots~)[0].status, "invalid")
  }
  assert_true(
    try {
      source.resources(roots=[
        { prefix: "", directory: "content", },
        { prefix: "", directory: "other", },
      ])
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.resources(roots=[{ prefix: "bad", directory: "content", }])
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "resource move preview preserves comments flags integers and rejects unsafe plans" {
  let text = workflow_kv3(
    "// keep\r\n{paths=[resource:\"materials/a.vmat\",resource:\"materials/sub/b.vmat\"] id=18446744073709551615 name=resource_name:\"materials/a.vmat\"}",
  )
  let source = @moonvalve.parse_kv3_preserving(text)
  let roots : Array[@moonvalve.ResourceRoot] = [
    { prefix: "", directory: "content", },
  ]
  let result = source.rewrite_resources(roots, {
    "content/materials": "content/new",
  })
  assert_true(result.text().contains("resource:\"new/a.vmat\""))
  assert_true(result.text().contains("resource:\"new/sub/b.vmat\""))
  assert_true(result.text().contains("resource_name:\"materials/a.vmat\""))
  assert_true(result.text().contains("18446744073709551615"))
  assert_true(result.text().contains("// keep\r\n"))
  assert_eq(source.text(), text)
  assert_true(
    try {
      source.rewrite_resources(roots, { "content/materials": "elsewhere/new" })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.rewrite_resources(roots, {
        "content/materials": "content/new",
        "content/materials/sub": "content/other",
      })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.rewrite_resources(roots, {
        "content/materials/a.vmat": "content/materials/b.vmat",
        "content/materials/b.vmat": "content/materials/c.vmat",
      })
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "resource batch rewrite handles thousands of original targets in one snapshot" {
  let output = StringBuilder()
  output.write_string("{ assets=[")
  for i in 0..<2000 {
    if i > 0 {
      output.write_string(",")
    }
    output.write_string("resource:\"old/" + i.to_string() + ".vmat\"")
  }
  output.write_string("] id=18446744073709551615 }")
  let source = @moonvalve.parse_kv3_preserving(workflow_kv3(output.to_string()))
  let roots : Array[@moonvalve.ResourceRoot] = [
    { prefix: "", directory: "content", },
  ]
  let changed = source.rewrite_resources(roots, { "content/old": "content/new" })
  let references = changed.resources(roots~)
  assert_eq(references.length(), 2000)
  assert_eq(references[1999].target, Some("content/new/1999.vmat"))
  assert_true(!changed.text().contains("old/"))
  assert_true(changed.text().contains("18446744073709551615"))
  assert_true(source.text().contains("old/0.vmat"))
}

///|
test "resource LSP uses host-confirmed states UTF16 navigation unsaved edits and rename preview" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  let uri = "file:///project/config.kv3"
  let text = workflow_kv3(
    "//😀\n{ a=resource:\"materials/moon.vmat\" b=resource:\"materials/absent.vmat\" }",
  )
  reference_notify(server, uri, text, opened=true) |> ignore
  let params : Json = {
    "textDocument": { "uri": "file:///project/config.kv3" },
    "position": { "line": 2, "character": 8 },
  }
  assert_eq(
    json_field(
      server.handle(lsp_request("textDocument/documentLink", params))[0],
      "result",
    ),
    Json::array([]),
  )
  server.handle(
    lsp_notify("moonvalve/setResourceRoots", {
      "roots": [{ "prefix": "", "uri": "file:///project/content" }],
    }),
  )
  |> ignore
  let targets = json_field(
    server.handle(lsp_request("moonvalve/resourceTargets", {}))[0],
    "result",
  )
  assert_true(targets.stringify().contains("content/materials/moon.vmat"))
  server.handle(
    lsp_notify("moonvalve/setResourceStates", {
      "states": [
        {
          "uri": "file:///project/content/materials/moon.vmat",
          "status": "present",
        },
        {
          "uri": "file:///project/content/materials/absent.vmat",
          "status": "unavailable",
        },
      ],
    }),
  )
  |> ignore
  let links = json_field(
    server.handle(lsp_request("textDocument/documentLink", params))[0],
    "result",
  )
  assert_true(links is Array(rows) && rows.length() == 1)
  let definition = json_field(
    server.handle(lsp_request("textDocument/definition", params))[0],
    "result",
  )
  assert_true(definition.stringify().contains("content/materials/moon.vmat"))
  let report = json_field(
    server.handle(lsp_request("moonvalve/resourceReferences", {}))[0],
    "result",
  )
  assert_true(report.stringify().contains("unavailable"))
  let notifications = server.handle(
    lsp_notify("moonvalve/setResourceStates", {
      "states": [
        {
          "uri": "file:///project/content/materials/absent.vmat",
          "status": "missing",
        },
      ],
    }),
  )
  assert_true(
    Json::array(notifications).stringify().contains("missing_resource"),
  )
  assert_true(!Json::array(notifications).stringify().contains("moon.vmat"))
  let preview = json_field(
    server.handle(
      lsp_request("workspace/willRenameFiles", {
        "files": [
          {
            "oldUri": "file:///project/content/materials/moon.vmat",
            "newUri": "file:///project/content/materials/new.vmat",
          },
        ],
      }),
    )[0],
    "result",
  )
  assert_true(preview.stringify().contains("materials/new.vmat"))
  let original = json_field(
    server.handle(lsp_request("moonvalve/resourceReferences", {}))[0],
    "result",
  )
  assert_true(original.stringify().contains("materials/moon.vmat"))
  let rejected = server.handle(
    lsp_request("workspace/willRenameFiles", {
      "files": [
        {
          "oldUri": "file:///project/content/materials/moon.vmat",
          "newUri": "file:///outside/new.vmat",
        },
      ],
    }),
  )
  assert_true(rejected[0].stringify().contains("error"))
}
