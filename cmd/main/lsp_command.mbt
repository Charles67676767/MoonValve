///|
fn run_lsp() -> Unit raise {
  let server = @valve.new_lsp_server()
  let framer = @valve.new_lsp_framer()
  let handle = host_stream_open("-")
  defer host_stream_close(handle)
  while !server.should_exit() {
    let bytes = host_stream_chunk(handle)
    if bytes.is_empty() {
      framer.finish()
      break
    }
    for packet in framer.feed(bytes) {
      let responses = match packet {
        @valve.LspRequest(request) => server.handle(request)
        @valve.LspInvalidJson =>
          [
            Json::object({
              "jsonrpc": Json::string("2.0"),
              "id": Json::null(),
              "error": Json::object({
                "code": Json::number(-32700),
                "message": Json::string("Invalid JSON"),
              }),
            }),
          ]
      }
      for response in responses {
        host_output_bytes(@valve.lsp_frame(response))
        host_output_check()
      }
      if server.should_exit() {
        break
      }
    }
  }
  host_exit_code(server.exit_code())
}
