///|
/// A bounded event writer. Conditions and root directives require a document
/// resolver and are rejected rather than silently changing their meaning.
struct StreamWriter {
  sink : (String) -> Unit raise
  mut depth : Int
  mut closed : Bool
}

///|
pub fn new_stream_writer(sink : (String) -> Unit raise) -> StreamWriter {
  { sink, depth: 0, closed: false, }
}

///|
pub fn StreamWriter::write(
  self : StreamWriter,
  event : StreamEvent,
) -> Unit raise {
  if self.closed {
    raise InvalidDocument("Stream writer is closed")
  }
  errdefer {
    self.closed = true
  }
  let builder = StringBuilder()
  match event {
    Pair(key, _) | BeginObject(key) => {
      if self.depth == 0 &&
        (
          key.equal_ignore_ascii_case("#include") ||
          key.equal_ignore_ascii_case("#base")
        ) {
        raise InvalidDocument(
          "Resolve root directives before stream formatting",
        )
      }
      write_indent(builder, self.depth)
      write_quoted(builder, key)
      match event {
        Pair(_, value) => {
          builder.write_string(" ")
          write_quoted(builder, value)
          builder.write_string("\n")
        }
        _ => ()
      }
    }
    EndObject => ()
    Condition(_, _) =>
      raise InvalidDocument(
        "Conditions require document evaluation before formatting",
      )
  }
  match event {
    BeginObject(_) => {
      if self.depth >= 128 {
        raise InvalidDocument("Stream writer exceeds depth 128")
      }
      builder.write_string("\n")
      write_indent(builder, self.depth)
      builder.write_string("{\n")
      self.depth += 1
    }
    EndObject => {
      if self.depth == 0 {
        raise InvalidDocument("Unmatched stream end")
      }
      self.depth -= 1
      write_indent(builder, self.depth)
      builder.write_string("}\n")
    }
    _ => ()
  }
  (self.sink)(builder.to_string())
}

///|
pub fn StreamWriter::finish(self : StreamWriter) -> Unit raise WriteError {
  if self.closed {
    raise InvalidDocument("Stream writer is closed")
  }
  self.closed = true
  if self.depth != 0 {
    raise InvalidDocument("Unclosed stream object")
  }
}
