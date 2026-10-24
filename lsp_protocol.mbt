///|
struct LspFramer {
  mut buffer : Bytes
  mut length : Int?
  mut closed : Bool
}

///|
pub(all) enum LspPacket {
  LspRequest(Json)
  LspInvalidJson
}

///|
pub fn new_lsp_framer() -> LspFramer {
  { buffer: b"", length: None, closed: false, }
}

///|
pub fn lsp_frame(message : Json) -> Bytes {
  let body = @utf8.encode(message.stringify()[:])
  @utf8.encode(("Content-Length: " + body.length().to_string() + "\r\n\r\n")[:]) +
  body
}

///|
pub fn LspFramer::feed(
  self : LspFramer,
  chunk : Bytes,
) -> Array[LspPacket] raise {
  if self.closed {
    raise Failure("LSP framer is closed")
  }
  errdefer {
    self.closed = true
  }
  if chunk.length() > 16842752 ||
    self.buffer.length() > 16846848 - chunk.length() {
    raise Failure("LSP input exceeds frame budget")
  }
  self.buffer = self.buffer + chunk
  let messages : Array[LspPacket] = []
  while true {
    if self.length is None {
      let mut end = -1
      let bytes = self.buffer
      for i in 0..<(bytes.length() - 3).max(0) {
        if bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10 {
          end = i
          break
        }
      }
      if end < 0 {
        if bytes.length() > 4096 {
          raise Failure("LSP header exceeds 4096 bytes")
        }
        break
      }
      if end > 4096 {
        raise Failure("LSP header exceeds 4096 bytes")
      }
      let header = @utf8.decode(bytes[:end])
      let mut length : Int? = None
      for line in header.split("\r\n") {
        guard line.find(":") is Some(colon) else {
          raise Failure("Malformed LSP header")
        }
        let name = line[:colon].to_owned()
        if name.equal_ignore_ascii_case("Content-Length") {
          if length is Some(_) {
            raise Failure("Duplicate Content-Length")
          }
          let value = line[colon + 1:].trim().to_owned()
          if !decimal_id(value) {
            raise Failure("Invalid Content-Length")
          }
          let count = @strconv.parse_int(value[:])
          if count < 1 || count > 16777216 {
            raise Failure("LSP message exceeds 16 MiB")
          }
          length = Some(count)
        }
      }
      if length is None {
        raise Failure("Missing Content-Length")
      }
      self.length = length
      self.buffer = bytes[end + 4:].to_owned()
    }
    let count = self.length.unwrap()
    if self.buffer.length() < count {
      break
    }
    let message = try {
      let text = @utf8.decode(self.buffer[:count], ignore_bom=false)
      LspRequest(@json.parse(text[:]))
    } catch {
      _ => LspInvalidJson
    }
    messages.push(message)
    self.buffer = self.buffer[count:].to_owned()
    self.length = None
  }
  messages
}

///|
pub fn LspFramer::finish(self : LspFramer) -> Unit raise {
  if self.closed {
    raise Failure("LSP framer is closed")
  }
  self.closed = true
  if !self.buffer.is_empty() || self.length is Some(_) {
    raise Failure("Incomplete LSP frame")
  }
}
