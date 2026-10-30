///|
fn lsp_request(verb : String, params : Json, id~ : Int32 = 1) -> Json {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string(verb),
    "id": Json::number(id.to_double()),
    "params": params,
  })
}

///|
fn lsp_notify(verb : String, params : Json) -> Json {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string(verb),
    "params": params,
  })
}

///|
fn json_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap()
    _ => abort("Expected object")
  }
}

///|
test "LSP lifecycle UTF16 incremental changes stale versions and close diagnostics" {
  let server = @moonvalve.new_lsp_server()
  let init = server.handle(lsp_request("initialize", Json::object({})))
  assert_eq(
    json_field(
      json_field(json_field(init[0], "result"), "capabilities"),
      "positionEncoding",
    ),
    Json::string("utf-16"),
  )
  let uri = "file:///project/main.vdf"
  let opened = server.handle(
    lsp_notify(
      "textDocument/didOpen",
      @json.parse(
        "{\"textDocument\":{\"uri\":\"file:///project/main.vdf\",\"version\":1,\"text\":\"r {k \\\"😀\\\"}\"}}",
      ),
    ),
  )
  assert_eq(
    json_field(json_field(opened[0], "params"), "diagnostics"),
    Json::array([]),
  )
  let change = @json.parse(
    "{\"textDocument\":{\"uri\":\"file:///project/main.vdf\",\"version\":2},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":8}},\"text\":\"Moon\"}]}",
  )
  assert_eq(
    server.handle(lsp_notify("textDocument/didChange", change)).length(),
    1,
  )
  let params = Json::object({
    "textDocument": Json::object({ "uri": Json::string(uri) }),
  })
  let formatted = server.handle(lsp_request("textDocument/formatting", params))
  guard json_field(formatted[0], "result") is Array(edits) else {
    fail("Expected formatting edits")
  }
  assert_eq(
    json_field(edits[0], "newText"),
    Json::string("r {\n  k \"Moon\"\n}\n"),
  )
  assert_eq(server.handle(lsp_notify("textDocument/didChange", change)), [])
  let closed = server.handle(lsp_notify("textDocument/didClose", params))
  assert_eq(
    json_field(json_field(closed[0], "params"), "diagnostics"),
    Json::array([]),
  )
  server.handle(lsp_request("shutdown", Json::object({}))) |> ignore
  server.handle(lsp_notify("exit", Json::object({}))) |> ignore
  assert_true(server.should_exit())
  assert_eq(server.exit_code(), 0)
}

///|
test "LSP project links definitions completions and symbols use only client supplied documents" {
  let server = @moonvalve.new_lsp_server()
  server.handle(lsp_request("initialize", Json::object({}))) |> ignore
  server.handle(
    lsp_notify(
      "moonvalve/setFile",
      @json.parse(
        "{\"uri\":\"file:///project/base.vdf\",\"text\":\"r {inherited yes}\"}",
      ),
    ),
  )
  |> ignore
  server.handle(
    lsp_notify(
      "textDocument/didOpen",
      @json.parse(
        "{\"textDocument\":{\"uri\":\"file:///project/main.vdf\",\"version\":1,\"text\":\"#base base.vdf\\nr\\n{\\n  k yes\\n}\"}}",
      ),
    ),
  )
  |> ignore
  let params = @json.parse(
    "{\"textDocument\":{\"uri\":\"file:///project/main.vdf\"},\"position\":{\"line\":0,\"character\":8}}",
  )
  let definition = json_field(
    server.handle(lsp_request("textDocument/definition", params))[0],
    "result",
  )
  guard definition is Array(locations) else { fail("Expected locations") }
  assert_eq(
    json_field(locations[0], "uri"),
    Json::string("file:///project/base.vdf"),
  )
  guard json_field(
      server.handle(lsp_request("textDocument/documentLink", params))[0],
      "result",
    )
    is Array(links) else {
    fail("Expected links")
  }
  assert_eq(links.length(), 1)
  guard json_field(
      server.handle(lsp_request("textDocument/completion", params))[0],
      "result",
    )
    is Array(completions) else {
    fail("Expected completions")
  }
  assert_eq(json_field(completions[0], "label"), Json::string("base.vdf"))
  guard json_field(
      server.handle(lsp_request("textDocument/documentSymbol", params))[0],
      "result",
    )
    is Array(symbols) else {
    fail("Expected symbols")
  }
  assert_eq(symbols.length(), 2)
  let formatted = json_field(
    server.handle(lsp_request("textDocument/formatting", params))[0],
    "result",
  )
  assert_true(formatted.stringify().contains("#base base.vdf"))
}

///|
test "LSP diagnostics positions and framing handle Unicode boundaries malformed frames and partial input" {
  assert_eq(
    @moonvalve.lsp_position("😀x\r\n中文", 1),
    @json.parse("{\"line\":0,\"character\":2}"),
  )
  assert_eq(
    @moonvalve.lsp_position("😀x\r\n中文", 5),
    @json.parse("{\"line\":1,\"character\":1}"),
  )
  let request = lsp_request(
    "initialize",
    Json::object({ "name": Json::string("中文😀") }),
  )
  let bytes = @moonvalve.lsp_frame(request)
  let framer = @moonvalve.new_lsp_framer()
  let packets : Array[@moonvalve.LspPacket] = []
  for byte in bytes {
    for packet in framer.feed(Bytes::from_array([byte])) {
      packets.push(packet)
    }
  }
  framer.finish()
  guard packets[0] is @moonvalve.LspRequest(actual) else {
    fail("Expected parsed request")
  }
  assert_eq(actual, request)
  let malformed = @moonvalve.new_lsp_framer()
  assert_true(
    malformed.feed(b"Content-Length: 1\r\n\r\n{")[0]
    is @moonvalve.LspInvalidJson,
  )
  for
    header in [
      "Content-Length: 1\r\nContent-Length: 1\r\n\r\nx", "Content-Length: -1\r\n\r\n",
      "X-Test: 1\r\n\r\n",
    ] {
    try @moonvalve.new_lsp_framer().feed(@utf8.encode(header[:])) catch {
      _ => ()
    } noraise {
      _ => fail("Expected malformed frame")
    }
  }
}
