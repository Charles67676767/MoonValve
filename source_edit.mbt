///|
priv struct SourceSpan {
  path : Array[Int]
  key_start : Int
  key_end : Int
  value_start : Int
  value_end : Int
  entry_end : Int
}

///|
/// A parsed source with scalar-index spans. Edit returns a new, reparsed source;
/// all characters outside the selected replacement range remain unchanged.
struct SourceDocument {
  source : String
  doc : Document
  spans : Array[SourceSpan]
  span_index : Map[String, SourceSpan]
  options : ParseOptions
  chars : Array[Char]
  linebreak : String
  unit : String
}

///|
pub fn parse_preserving(
  input : String,
  options? : ParseOptions = ParseOptions::default(),
) -> SourceDocument raise {
  if options.conditions is Some(_) {
    raise InvalidEdit(
      "Source documents retain all conditions; call evaluate for a filtered view",
    )
  }
  let (doc, _, spans) = parse_with_spans(input, options, true, true)
  let span_index : Map[String, SourceSpan] = Map([])
  for span in spans {
    span_index[index_key(span.path)] = span
  }
  let result = SourceDocument::{
    source: input,
    doc,
    spans,
    span_index,
    options,
    chars: input.to_array(),
    linebreak: if input.contains("\r\n") {
      "\r\n"
    } else if input.contains("\r") {
      "\r"
    } else {
      "\n"
    },
    unit: "  ",
  }
  { ..result, unit: result.detect_indent_unit(), }
}

///|
pub fn SourceDocument::text(self : SourceDocument) -> String {
  self.source
}

///|
pub fn SourceDocument::document(self : SourceDocument) -> Document {
  self.doc
}

///|
/// Evaluate a source without changing its raw view. Root file directives still
/// require load_resolved with an explicitly supplied loader.
pub fn SourceDocument::evaluate(
  self : SourceDocument,
  symbols : Array[String],
) -> Document raise ParseError {
  parse(self.source, options={ ..self.options, conditions: Some(symbols), })
}

///|
fn SourceDocument::span(
  self : SourceDocument,
  path : Array[Int],
) -> SourceSpan raise EditError {
  match self.span_index.get(index_key(path)) {
    Some(span) => span
    None => raise InvalidEdit("Source span was not found")
  }
}

///|
/// Supports the same occurrence-aware edits as Document::edit. Comments outside
/// replaced values remain intact; removing an entry leaves surrounding comments.
/// Newly inserted or replaced structures use canonical escaped KV1 formatting.
pub fn SourceDocument::edit(
  self : SourceDocument,
  path : Array[Selector],
  operation : Edit,
) -> SourceDocument raise {
  // Validate the operation before touching source and determine the exact indices.
  let expected = self.doc.edit(path, operation)
  let indices : Array[Int] = []
  let mut selected = Value::Object(self.doc.entries)
  for selector in path {
    guard selected is Object(entries) else {
      raise InvalidEdit("Path crosses text")
    }
    let mut seen = 0
    for i in 0..<entries.length() {
      if entries[i].key == selector.key {
        if seen == selector.occurrence {
          indices.push(i)
          selected = entries[i].value
          break
        }
        seen += 1
      }
    }
  }
  let chars = self.chars
  let mut start = 0
  let mut end = chars.length()
  let builder = StringBuilder()
  match operation {
    Replace(value) =>
      if indices.is_empty() {
        self.render_entries(builder, expected.entries, "", true)
      } else {
        let span = self.span(indices)
        start = span.value_start
        end = span.value_end
        match value {
          Text(s) =>
            self.render_string(builder, s, chars[span.value_start] == '"')
          Object(children) => {
            let indent = self.line_indent(span.key_start)
            builder.write_string("{" + self.newline())
            self.render_entries(
              builder,
              children,
              indent + self.indent_unit(),
              true,
            )
            builder.write_string(indent)
            builder.write_string("}")
          }
        }
      }
    Rename(key) => {
      let span = self.span(indices)
      start = span.key_start
      end = span.key_end
      self.render_string(builder, key, chars[span.key_start] == '"')
    }
    Remove => {
      let span = self.span(indices)
      start = span.key_start
      end = span.entry_end
    }
    Insert(index, entry) => {
      guard selected is Object(entries) else {
        raise InvalidEdit("Insertion target is not an object")
      }
      start = if index < entries.length() {
        let child = indices.map(i => i)
        child.push(index)
        self.span(child).key_start
      } else if indices.is_empty() {
        chars.length()
      } else {
        self.span(indices).value_end - 1
      }
      end = start
      let indent = if index < entries.length() {
        let child = [..indices, index]
        self.line_indent(self.span(child).key_start)
      } else if indices.is_empty() {
        ""
      } else {
        self.line_indent(self.span(indices).key_start) + self.indent_unit()
      }
      // Insertion starts on its own line; existing trivia stays attached to its
      // original entry. Only the newly written text adopts surrounding style.
      builder.write_string(self.newline())
      let quoted = if !entries.is_empty() {
        let neighbor = [
          ..indices,
          if index < entries.length() {
            index
          } else {
            entries.length() - 1
          },
        ]
        chars[self.span(neighbor).key_start] == '"'
      } else {
        true
      }
      self.render_entries(builder, [entry], indent, quoted)
      if index < entries.length() {
        builder.write_string(indent)
      }
    }
  }
  let source = String::from_array(chars[:start].to_owned()) +
    builder.to_string() +
    String::from_array(chars[end:].to_owned())
  let result = parse_preserving(source, options=self.options)
  if result.doc != expected {
    raise InvalidEdit("Source edit could not preserve requested semantics")
  }
  result
}

///|
fn SourceDocument::newline(self : SourceDocument) -> String {
  self.linebreak
}

///|
fn SourceDocument::line_indent(self : SourceDocument, offset : Int) -> String {
  let chars = self.chars
  let mut start = offset
  while start > 0 && chars[start - 1] != '\n' && chars[start - 1] != '\r' {
    start -= 1
  }
  let prefix = chars[start:offset]
  if prefix.all(c => c == ' ' || c == '\t') {
    String::from_array(prefix.to_owned())
  } else {
    ""
  }
}

///|
fn SourceDocument::indent_unit(self : SourceDocument) -> String {
  self.unit
}

///|
fn SourceDocument::detect_indent_unit(self : SourceDocument) -> String {
  for span in self.spans {
    if span.path.length() > 1 {
      let indent = self.line_indent(span.key_start)
      let parent = self.span(span.path[:span.path.length() - 1].to_owned()) catch {
        _ => continue
      }
      let parent_indent = self.line_indent(parent.key_start)
      if indent.has_prefix(parent_indent) &&
        indent.length() > parent_indent.length() {
        return indent[parent_indent.length():].to_owned()
      }
    }
  }
  "  "
}

///|
fn SourceDocument::render_string(
  self : SourceDocument,
  builder : StringBuilder,
  text : String,
  quoted : Bool,
) -> Unit raise WriteError {
  if text.contains("\u0000") {
    raise InvalidDocument("NUL cannot be written")
  }
  let bare = !text.is_empty() &&
    !text.has_prefix("//") &&
    !text.has_prefix("[") &&
    text.all(c => !is_space(c) && c != '{' && c != '}' && c != '"' && c != '=')
  if !quoted && bare {
    builder.write_string(text)
    return
  }
  if self.options.escape_sequences {
    write_quoted(builder, text)
  } else {
    if text.contains("\"") {
      raise InvalidDocument("A quote cannot be represented in literal mode")
    }
    builder.write_string("\"" + text + "\"")
  }
}

///|
fn SourceDocument::render_entries(
  self : SourceDocument,
  builder : StringBuilder,
  entries : Array[Entry],
  indent : String,
  quoted : Bool,
  depth? : Int = 0,
) -> Unit raise WriteError {
  if depth > 128 {
    raise InvalidDocument("Source rendering exceeds 128 levels")
  }
  for entry in entries {
    builder.write_string(indent)
    self.render_string(builder, entry.key, quoted)
    match entry.value {
      Text(s) => {
        builder.write_string(" ")
        self.render_string(builder, s, quoted)
        builder.write_string(self.newline())
      }
      Object(children) => {
        builder.write_string(self.newline() + indent + "{" + self.newline())
        if indent.length() > 1024 {
          raise InvalidDocument("Object indentation exceeds depth budget")
        }
        self.render_entries(
          builder,
          children,
          indent + self.indent_unit(),
          quoted,
          depth=depth + 1,
        )
        builder.write_string(indent + "}" + self.newline())
      }
    }
  }
}
