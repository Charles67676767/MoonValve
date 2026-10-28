///|
test "KV3 LSP symbols folding hover and literal completion preserve typed values" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  let uri = "file:///project/typed.kv3"
  let text = kv3_header_text() +
    "//😀\r\n{\r\n name=\"Moon\"\r\n enabled=true\r\n n=18446744073709551615\r\n resources=resource:[\r\n  \"a\",\r\n  {path=\"b\"}\r\n ]\r\n}"
  reference_notify(server, uri, text, opened=true) |> ignore
  let params = Json::object({
    "textDocument": Json::object({ "uri": Json::string(uri) }),
  })
  let symbols = server.handle(
    lsp_request("textDocument/documentSymbol", params),
  )
  let result = json_field(symbols[0], "result")
  assert_true(result.stringify().contains("18446744073709551615"))
  assert_true(result.stringify().contains("resource: array"))
  assert_true(result.stringify().contains("[1]"))
  let folding = server.handle(lsp_request("textDocument/foldingRange", params))
  guard json_field(folding[0], "result") is Array(ranges) else {
    fail("Expected ranges")
  }
  assert_eq(ranges.length(), 2)
  let hover_params = Json::object({
    "textDocument": Json::object({ "uri": Json::string(uri) }),
    "position": Json::object({
      "line": Json::number(5),
      "character": Json::number(3),
    }),
  })
  let hover = server.handle(lsp_request("textDocument/hover", hover_params))
  assert_true(hover[0].stringify().contains("integer: 18446744073709551615"))
  let completion = server.handle(
    lsp_request("textDocument/completion", hover_params),
  )
  assert_true(completion[0].stringify().contains("resource_name"))
  let link = server.handle(lsp_request("textDocument/documentLink", params))
  assert_eq(json_field(link[0], "result"), Json::array([]))
}

///|
test "KV3 navigation recovers after incomplete unsaved input" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  let uri = "file:///project/recover.kv3"
  reference_notify(server, uri, kv3_header_text() + "{broken=", opened=true)
  |> ignore
  let params = Json::object({
    "textDocument": Json::object({ "uri": Json::string(uri) }),
  })
  assert_eq(
    json_field(
      server.handle(lsp_request("textDocument/documentSymbol", params))[0],
      "result",
    ),
    Json::array([]),
  )
  reference_notify(
    server,
    uri,
    kv3_header_text() + "{enabled=false}",
    opened=true,
  )
  |> ignore
  assert_true(
    server.handle(lsp_request("textDocument/documentSymbol", params))[0]
    .stringify()
    .contains("enabled"),
  )
}
