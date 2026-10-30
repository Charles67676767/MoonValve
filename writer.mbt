///|
pub suberror WriteError {
  InvalidDocument(String)
} derive(Debug)

///|
/// Canonical escaped KV1 text. All keys and strings are quoted; order and
/// duplicates are retained. Comments and original whitespace are not retained.
pub fn stringify(document : Document) -> String raise WriteError {
  let builder = StringBuilder()
  write_entries(builder, document.entries, 0)
  builder.to_string()
}

///|
fn write_quoted(
  builder : StringBuilder,
  text : String,
) -> Unit raise WriteError {
  builder.write_char('"')
  for c in text {
    match c {
      '"' => builder.write_string("\\\"")
      '\\' => builder.write_string("\\\\")
      '\n' => builder.write_string("\\n")
      '\r' => builder.write_string("\\r")
      '\t' => builder.write_string("\\t")
      _ => {
        if c.to_int() == 0 {
          raise InvalidDocument("NUL cannot be serialized as KV1 text")
        }
        builder.write_char(c)
      }
    }
  }
  builder.write_char('"')
}

///|
fn write_indent(builder : StringBuilder, depth : Int32) -> Unit {
  for _ in 0..<depth {
    builder.write_string("  ")
  }
}

///|
fn write_entries(
  builder : StringBuilder,
  entries : Array[Entry],
  depth : Int32,
) -> Unit raise WriteError {
  if depth > 128 {
    raise InvalidDocument("Object exceeds writer depth limit of 128")
  }
  for entry in entries {
    if depth == 0 &&
      (
        entry.key.equal_ignore_ascii_case("#include") ||
        entry.key.equal_ignore_ascii_case("#base")
      ) {
      raise InvalidDocument(
        "Directive keys cannot be serialized as ordinary entries",
      )
    }
    write_indent(builder, depth)
    write_quoted(builder, entry.key)
    match entry.value {
      Text(text) => {
        builder.write_string(" ")
        write_quoted(builder, text)
        builder.write_string("\n")
      }
      Object(children) => {
        builder.write_string("\n")
        write_indent(builder, depth)
        builder.write_string("{\n")
        write_entries(builder, children, depth + 1)
        write_indent(builder, depth)
        builder.write_string("}\n")
      }
    }
  }
}
