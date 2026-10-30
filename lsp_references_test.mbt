///|
fn reference_notify(
  server : @moonvalve.LspServer,
  uri : String,
  text : String,
  opened~ : Bool = false,
) -> Array[Json] {
  if opened {
    server.handle(
      lsp_notify(
        "textDocument/didOpen",
        Json::object({
          "textDocument": Json::object({
            "uri": Json::string(uri),
            "version": Json::number(7),
            "text": Json::string(text),
          }),
        }),
      ),
    )
  } else {
    server.handle(
      lsp_notify(
        "moonvalve/setFile",
        Json::object({ "uri": Json::string(uri), "text": Json::string(text) }),
      ),
    )
  }
}

///|
test "LSP confirmed missing targets, cycle chains and dependent refresh" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  let uri = "file:///project/main.vdf"
  reference_notify(server, uri, "#base base.vdf\nr {}", opened=true) |> ignore
  reference_notify(
    server, "file:///project/base.vdf", "#include missing.vdf\nr {}",
  )
  |> ignore
  let result = server.handle(
    lsp_request("moonvalve/referenceTargets", Json::object({})),
  )
  assert_true(
    json_field(result[0], "result")
    .stringify()
    .contains("file:///project/missing.vdf"),
  )
  // An unloaded target is not reported missing until the host confirms absence.
  let clean = reference_notify(server, uri, "#base base.vdf\nr {}", opened=true)
  assert_eq(
    json_field(json_field(clean[0], "params"), "diagnostics"),
    Json::array([]),
  )
  let missing = server.handle(
    lsp_notify(
      "moonvalve/setMissingFiles",
      Json::object({
        "uris": Json::array([Json::string("file:///project/missing.vdf")]),
      }),
    ),
  )
  assert_true(missing[0].stringify().contains("missing_reference"))
  assert_true(
    missing[0]
    .stringify()
    .contains("/project/main.vdf -> /project/base.vdf -> /project/missing.vdf"),
  )
  // Loading the previously missing target clears the inherited error immediately.
  let cleared = reference_notify(server, "file:///project/missing.vdf", "r {}")
  assert_eq(
    json_field(json_field(cleared[0], "params"), "diagnostics"),
    Json::array([]),
  )
  let cycle = reference_notify(
    server, "file:///project/base.vdf", "#include main.vdf\nr {}",
  )
  assert_true(cycle[0].stringify().contains("reference_cycle"))
  assert_true(
    cycle[0]
    .stringify()
    .contains("/project/main.vdf -> /project/base.vdf -> /project/main.vdf"),
  )
  let fixed = reference_notify(server, "file:///project/base.vdf", "r {}")
  assert_eq(
    json_field(json_field(fixed[0], "params"), "diagnostics"),
    Json::array([]),
  )
}

///|
test "LSP rename preview rebases outgoing references and leaves original cache unchanged" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  reference_notify(
    server,
    "file:///project/main.vdf",
    "// keep\n#base cfg/base.vdf\nr {}",
    opened=true,
  )
  |> ignore
  reference_notify(
    server, "file:///project/cfg/base.vdf", "#include ../extra.vdf\nr {}",
  )
  |> ignore
  reference_notify(server, "file:///project/extra.vdf", "r {}") |> ignore
  let params = @json.parse(
    "{\"files\":[{\"oldUri\":\"file:///project/cfg/base.vdf\",\"newUri\":\"file:///project/new/deep/base.vdf\"}]}",
  )
  let preview = server.handle(lsp_request("workspace/willRenameFiles", params))
  let text = json_field(preview[0], "result").stringify()
  assert_true(text.contains("new/deep/base.vdf"))
  assert_true(text.contains("../../extra.vdf"))
  assert_true(text.contains("keep"))
  assert_true(text.contains("\"version\":7"))
  assert_true(text.contains("\"version\":null"))
  let links = server.handle(
    lsp_request(
      "textDocument/documentLink",
      @json.parse("{\"textDocument\":{\"uri\":\"file:///project/main.vdf\"}}"),
    ),
  )
  assert_true(links[0].stringify().contains("file:///project/cfg/base.vdf"))
  let collision = server.handle(
    lsp_request(
      "workspace/willRenameFiles",
      @json.parse(
        "{\"files\":[{\"oldUri\":\"file:///project/cfg/base.vdf\",\"newUri\":\"file:///project/extra.vdf\"}]}",
      ),
    ),
  )
  assert_true(collision[0].stringify().contains("error"))
  let folder = server.handle(
    lsp_request(
      "workspace/willRenameFiles",
      @json.parse(
        "{\"files\":[{\"oldUri\":\"file:///project/cfg\",\"newUri\":\"file:///project/moved\"}]}",
      ),
    ),
  )
  assert_true(folder[0].stringify().contains("moved/base.vdf"))
}

///|
test "LSP rename keeps encoded URI spelling and dirty version" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  reference_notify(
    server,
    "file:///c%3A/project/old%20name.vdf",
    "r {k unsaved}",
    opened=true,
  )
  |> ignore
  let params = @json.parse(
    "{\"files\":[{\"oldUri\":\"file:///c%3A/project/old%20name.vdf\",\"newUri\":\"file:///c%3A/project/new%20name.vdf\"}]}",
  )
  server.handle(lsp_notify("workspace/didRenameFiles", params)) |> ignore
  let change = @json.parse(
    "{\"textDocument\":{\"uri\":\"file:///c%3A/project/new%20name.vdf\",\"version\":8},\"contentChanges\":[{\"text\":\"r {k changed}\"}]}",
  )
  let changed = server.handle(lsp_notify("textDocument/didChange", change))
  assert_true(!changed[0].stringify().contains("logMessage"))
  let formatted = server.handle(
    lsp_request(
      "textDocument/formatting",
      @json.parse(
        "{\"textDocument\":{\"uri\":\"file:///c%3A/project/new%20name.vdf\"}}",
      ),
    ),
  )
  assert_true(formatted[0].stringify().contains("changed"))
}
