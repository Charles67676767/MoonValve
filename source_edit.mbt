///|
struct SourceSpan {
  path : Array[Int]
  key_start : Int
  key_end : Int
  value_start : Int
  value_end : Int
}

///|
/// A parsed source with scalar-index spans. Edit returns a new, reparsed source;
/// all characters outside the selected replacement range remain unchanged.
pub struct SourceDocument {
  source : String
  doc : Document
  spans : Array[SourceSpan]
  options : ParseOptions
}

///|
pub fn parse_preserving(
  input : String,
  options? : ParseOptions = ParseOptions::default(),
) -> SourceDocument raise {
  if !options.escape_sequences || options.conditions is Some(_) {
    raise InvalidEdit(
      "Source editing requires escaped strings and disabled condition evaluation",
    )
  }
  let (doc, _, spans) = parse_with_spans(input, options, false, true)
  { source: input, doc, spans, options, }
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
fn SourceDocument::span(
  self : SourceDocument,
  path : Array[Int],
) -> SourceSpan raise EditError {
  for span in self.spans {
    if span.path == path {
      return span
    }
  }
  raise InvalidEdit("Source span was not found")
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
  let chars = self.source.to_array()
  let mut start = 0
  let mut end = chars.length()
  let builder = StringBuilder()
  match operation {
    Replace(value) =>
      if indices.is_empty() {
        builder.write_string(stringify(expected))
      } else {
        let span = self.span(indices)
        start = span.value_start
        end = span.value_end
        match value {
          Text(s) => write_quoted(builder, s)
          Object(children) => {
            builder.write_string("{\n")
            write_entries(builder, children, indices.length())
            write_indent(builder, indices.length() - 1)
            builder.write_string("}")
          }
        }
      }
    Rename(key) => {
      let span = self.span(indices)
      start = span.key_start
      end = span.key_end
      write_quoted(builder, key)
    }
    Remove => {
      let span = self.span(indices)
      start = span.key_start
      end = span.value_end
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
      builder.write_string("\n")
      write_entries(builder, [entry], indices.length())
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
